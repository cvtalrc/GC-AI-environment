"""Daemon-independent tests of the rendered deployment contract."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
import tempfile
import stat
import sys
import shlex
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class ConfigurationTests(unittest.TestCase):
    def render(self, filename):
        env = dict(os.environ,
                   GCAI_BACKEND_IMAGE='example/backend@sha256:' + '0' * 64,
                   GCAI_FRONTEND_IMAGE='example/frontend@sha256:' + '0' * 64,
                   GCAI_MYSQL_IMAGE='mysql:8.4@sha256:' + '0' * 64,
                   GCAI_TRUSTED_ORIGINS='https://example.test')
        result = subprocess.run(['docker', 'compose', '-f', filename, 'config', '--format', 'json'],
                                cwd=ROOT, env=env, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_hosted_only_tls_proxy_published_and_private_dependencies(self):
        config = self.render('compose.hosted.yml')
        for name, service in config['services'].items():
            if name != 'proxy':
                self.assertFalse(service.get('ports'), name)
        self.assertEqual([p['published'] for p in config['services']['proxy']['ports']], ['443'])
        self.assertTrue(config['networks']['application']['internal'])
        self.assertTrue(config['networks']['registry']['internal'])
        backend = config['services']['backend']
        self.assertEqual(backend['environment']['DB_USER'], 'gcai')
        self.assertNotIn('DB_PASSWORD', backend['environment'])
        self.assertIn('--workers=1', backend['command'])
        self.assertIn('--threads=4', backend['command'])
        self.assertNotIn('--preload', backend['command'])
        self.assertTrue(backend['read_only'])
        self.assertEqual(backend['user'], '10001:10001')
        janitor = config['services']['janitor']
        self.assertEqual(janitor['network_mode'], 'none')
        self.assertIn('sleep 3600', janitor['command'][0])
        self.assertEqual(janitor['volumes'][0]['source'], backend['volumes'][0]['source'])
        self.assertEqual(config['services']['db']['environment']['MYSQL_ROOT_PASSWORD_FILE'],
                         '/run/gcai/db_root_password')

    def test_only_proxy_has_external_edge_for_published_ports(self):
        for filename in ['docker-compose.yml', 'compose.hosted.yml']:
            with self.subTest(profile=filename):
                config = self.render(filename)
                self.assertFalse(config['networks']['edge'].get('internal', False))
                self.assertEqual(set(config['services']['proxy']['networks']), {'application','edge'})
                for name, service in config['services'].items():
                    if name != 'proxy':
                        self.assertNotIn('edge', service.get('networks', {}), name)
                        self.assertFalse(service.get('ports'), name)
                for name in ['backend','db']:
                    for network in config['services'][name]['networks']:
                        self.assertTrue(config['networks'][network]['internal'])

    def test_rendered_database_healthcheck_writes_valid_private_client_configuration(self):
        health = self.render('compose.hosted.yml')['services']['db']['healthcheck']['test']
        self.assertEqual(health[0], 'CMD-SHELL')
        self.assertIn('/run/gcai/db_app_password', health[1])
        self.assertNotIn('/run/gcai/db_root_password', health[1])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            secret = directory / 'password'
            secret.write_text('synthetic-test-password')
            secret.chmod(0o600)
            captured_path = directory / 'configuration-path'
            stub = directory / 'mysql'
            stub.write_text('#!' + sys.executable + '\n' + """
import configparser,os,stat,sys
from pathlib import Path
arguments = sys.argv[1:]
filename = next(arg.split('=',1)[1] for arg in arguments if arg.startswith('--defaults-extra-file='))
path = Path(filename)
assert stat.S_IMODE(path.stat().st_mode) == 0o600
config = configparser.ConfigParser(interpolation=None)
config.read(str(path))
assert config.get('client','user') == 'gcai'
assert config.get('client','password') == 'synthetic-test-password'
assert '--protocol=TCP' in arguments and '-h127.0.0.1' in arguments
assert arguments[-2:] == ['-e','SELECT 1']
Path(os.environ['GCAI_CAPTURE_CONFIG']).write_text(filename)
print(1)
""")
            stub.chmod(0o700)
            # Compose's config serializer escapes dollars in normalized output.
            command = health[1].replace('$$', '$').replace(
                '/run/gcai/db_app_password', shlex.quote(str(secret)))
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                       GCAI_CAPTURE_CONFIG=str(captured_path))
            process = subprocess.run(['/bin/sh','-c',command], env=env, capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertFalse(Path(captured_path.read_text()).exists(), 'Private temporary client config leaked')
            # A root TCP probe regresses the confirmed localhost-only root restriction.
            wrong_user = command.replace('user=gcai', 'user=root')
            process = subprocess.run(['/bin/sh','-c',wrong_user], env=env, capture_output=True, text=True)
            self.assertNotEqual(process.returncode, 0)
            # The actual shell/parser probe also detects the hypothesized literal-backslash defect.
            broken = command.replace('\\n', '\\\\n')
            process = subprocess.run(['/bin/sh','-c',broken], env=env, capture_output=True, text=True)
            self.assertNotEqual(process.returncode, 0)

    def test_secret_consumers_get_narrow_readonly_private_volumes(self):
        config = self.render('compose.hosted.yml')
        for name, expected in [('backend', 'backend-secrets'), ('db', 'mysql-secrets'), ('proxy', 'proxy-secrets')]:
            service = config['services'][name]
            self.assertFalse(service.get('secrets'), name)
            self.assertEqual(service['depends_on']['secret-init']['condition'], 'service_completed_successfully')
            mount = next(v for v in service['volumes'] if v['target'] == '/run/gcai')
            self.assertEqual(mount['source'], expected)
            self.assertTrue(mount['read_only'])
        self.assertEqual(config['services']['db']['environment']['MYSQL_ROOT_HOST'], 'localhost')
        for script in ['10-import-registry.sh', '20-create-app-user.sh']:
            self.assertFalse((ROOT / 'scripts' / script).stat().st_mode & 0o111)

    def test_prepared_secret_mode_and_rotation(self):
        spec = importlib.util.spec_from_file_location('prepare_secrets', ROOT / 'scripts/prepare-secrets.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source'
            target = Path(temporary) / 'consumer/secret'
            source.write_bytes(b'first-private-value')
            source.chmod(0o600)
            module.prepare(source, target, os.getuid(), os.getgid())
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o400)
            self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
            source.write_bytes(b'rotated-private-value')
            module.prepare(source, target, os.getuid(), os.getgid())
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_local_ports_are_loopback_only(self):
        config = self.render('docker-compose.yml')
        ports = [p for service in config['services'].values() for p in service.get('ports', [])]
        self.assertEqual(len(ports), 1)
        self.assertEqual(ports[0]['host_ip'], '127.0.0.1')

    def test_authentication_covers_frontend_and_api(self):
        config = (ROOT / 'nginx/hosted.conf').read_text()
        self.assertIn("auth_basic 'GC-AI workspace';", config)
        self.assertIn('auth_basic_user_file /run/gcai/proxy_htpasswd;', config)
        self.assertNotIn('auth_basic off', config)
        self.assertIn('proxy_read_timeout 180s;', config)
        self.assertIn('limit_conn api_connections 4;', config)
        self.assertIn('server_name _;', config)
        self.assertIn('ssl_protocols TLSv1.2 TLSv1.3;', config)
        self.assertIn("proxy_set_header Authorization '';", config)
        self.assertIn('access_log off;', config)

    def test_legacy_import_secret_is_readable_after_mysql_uid_drop_and_removed(self):
        spec = importlib.util.spec_from_file_location('import_assets', ROOT / 'scripts/import-assets.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for fail_dump in (False, True):
            with self.subTest(fail_dump=fail_dump), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                client = directory / 'legacy.cnf'
                client.write_text('[client]\nuser=root\npassword=private-test-value\n')
                client.chmod(0o600)
                output = directory / 'assets'
                captured = {'commands': [], 'removed': [], 'password': None, 'ready_probes': 0}

                def run(*arguments, **kwargs):
                    captured['commands'].append(arguments)
                    if arguments[0] == 'create' and '--entrypoint' in arguments:
                        return SimpleNamespace(stdout='checkpoint-id')
                    if arguments[0] == 'create':
                        password_mount = next(arg for arg in arguments
                                              if 'dst=/run/secrets/legacy-root-password,' in arg)
                        password = Path(password_mount.split('src=', 1)[1].split(',', 1)[0])
                        captured['password'] = password
                        # File-only bind mounts bypass the private host parent directory.
                        # mysql must be able to read it after the official UID drop.
                        self.assertEqual(stat.S_IMODE(password.stat().st_mode), 0o444)
                        self.assertEqual(stat.S_IMODE(password.parent.stat().st_mode), 0o700)
                        self.assertEqual(password.read_text(), 'private-test-value')
                        self.assertEqual(stat.S_IMODE(client.stat().st_mode), 0o600)
                        self.assertIn('--user', arguments)
                        self.assertIn('0:0', arguments)
                        return SimpleNamespace(stdout='database-id')
                    if arguments[0] == 'cp':
                        Path(arguments[2]).write_bytes(b'trusted-checkpoint-fixture')
                    elif arguments[0] == 'exec':
                        self.assertEqual(captured['ready_probes'], 2, 'Dump started before final server readiness')
                        self.assertEqual(arguments[1:3], ('--user', '0:0'))
                        if fail_dump:
                            raise subprocess.CalledProcessError(1, ['mysqldump'])
                        kwargs['stdout'].write(b'CREATE TABLE parts (name TEXT);\n')
                    return SimpleNamespace(returncode=0)

                def subprocess_run(arguments, **kwargs):
                    captured['commands'].append(tuple(arguments))
                    if arguments[1] == 'exec':
                        self.assertEqual(arguments[2:4], ['--user', '0:0'])
                        self.assertIn('@@GLOBAL.skip_networking', arguments[-1])
                        captured['ready_probes'] += 1
                        value = b'1\t1\n' if captured['ready_probes'] == 1 else b'1\t0\n'
                        return SimpleNamespace(returncode=0, stdout=value)
                    if arguments[1] == 'rm':
                        captured['removed'].append(arguments[-1])
                        return SimpleNamespace(returncode=0)
                    self.fail('Unexpected docker subprocess')

                argv = ['import-assets', '--checkpoint-image', 'backend@sha256:' + 'a' * 64,
                        '--database-image', 'database@sha256:' + 'b' * 64,
                        '--checkpoint-path', '/models/checkpoint.pth', '--legacy-client-file', str(client),
                        '--output', str(output)]
                with patch.object(module, 'run', side_effect=run), \
                        patch.object(module.subprocess, 'run', side_effect=subprocess_run), \
                        patch('sys.argv', argv), patch.object(module.time, 'sleep'):
                    if fail_dump:
                        with self.assertRaises(subprocess.CalledProcessError):
                            module.main()
                    else:
                        module.main()
                self.assertFalse(captured['password'].exists())
                self.assertCountEqual(captured['removed'], ['database-id', 'checkpoint-id'])
                self.assertEqual((output / 'import-receipt.json').exists(), not fail_dump)
                self.assertNotIn('private-test-value', repr(captured['commands']))

    def test_importer_requires_digest_and_never_starts_checkpoint(self):
        spec = importlib.util.spec_from_file_location('import_assets', ROOT / 'scripts/import-assets.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.pinned('example@sha256:' + 'a' * 64), 'example@sha256:' + 'a' * 64)
        for ref in ['example:latest', 'example', 'example@sha256:short']:
            with self.assertRaises(Exception):
                module.pinned(ref)
        source = (ROOT / 'scripts/import-assets.py').read_text()
        self.assertIn("run('start', database", source)
        self.assertNotIn("run('start', checkpoint", source)
        self.assertIn("'iGEM2024', 'parts'", source)


if __name__ == '__main__':
    unittest.main()
