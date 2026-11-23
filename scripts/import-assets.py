#!/usr/bin/env python3
"""Import only checkpoint and registry table from pinned legacy images."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import tempfile
import time


def run(*arguments, **kwargs):
    return subprocess.run(['docker', *arguments], check=True, **kwargs)


def pinned(value):
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', value):
        raise argparse.ArgumentTypeError('Use an image reference pinned by SHA256 digest')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint-image', required=True, type=pinned)
    parser.add_argument('--database-image', required=True, type=pinned)
    parser.add_argument('--checkpoint-path', required=True, help='Absolute path inside the legacy image')
    parser.add_argument('--legacy-client-file', required=True, type=Path,
                        help='Private [client] file containing legacy user/password; never committed')
    parser.add_argument('--output', type=Path, default=Path('assets'))
    args = parser.parse_args()
    if not args.checkpoint_path.startswith('/'):
        parser.error('--checkpoint-path must be absolute inside the image')
    if args.legacy_client_file.stat().st_mode & 0o077:
        parser.error('Legacy credentials file must have permissions 0600')
    credentials = configparser.ConfigParser(interpolation=None)
    credentials.read(args.legacy_client_file)
    if not credentials.has_option('client', 'password'):
        parser.error('Legacy [client] password is required')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any((args.output / name).exists() for name in ('160_model.pth', 'registry.sql', 'import-receipt.json')):
        parser.error('Output already contains imported assets; choose an empty directory')
    containers = []
    with tempfile.TemporaryDirectory(prefix='.import-', dir=args.output) as temporary:
        stage = Path(temporary)
        password = stage / 'legacy-root-password'
        password.write_text(credentials.get('client', 'password'))
        # The database entrypoint may reopen _FILE after dropping to mysql.
        # This ephemeral file-only bind must be readable by that UID. Its host
        # parent remains 0700 and only this isolated database mounts the file.
        password.chmod(0o444)
        try:
            # The checkpoint container is NEVER started; no pickle/application executes.
            checkpoint = run('create', '--network', 'none', '--entrypoint', '/bin/false',
                             args.checkpoint_image, capture_output=True, text=True).stdout.strip()
            containers.append(checkpoint)
            run('cp', f'{checkpoint}:{args.checkpoint_path}', str(stage / '160_model.pth'))
            database = run('create', '--network', 'none', '--user', '0:0',
                           '--env', 'MYSQL_ROOT_PASSWORD=',
                           '--env', 'MYSQL_ROOT_PASSWORD_FILE=/run/secrets/legacy-root-password',
                           '--mount', f'type=bind,src={password.resolve()},dst=/run/secrets/legacy-root-password,readonly',
                           '--mount', f'type=bind,src={args.legacy_client_file.resolve()},dst=/run/secrets/legacy.cnf,readonly',
                           args.database_image, capture_output=True, text=True).stdout.strip()
            containers.append(database)
            # Only the database entrypoint executes, isolated with no published ports.
            run('start', database, stdout=subprocess.DEVNULL)
            # The official temporary initialization server accepts socket queries
            # before registry import finishes, but runs with skip_networking=1.
            # Wait for the final network-enabled server while retaining local
            # socket authentication and the isolated no-network container.
            for attempt in range(120):
                ready = subprocess.run(['docker', 'exec', '--user', '0:0', database, 'mysql',
                                        '--defaults-extra-file=/run/secrets/legacy.cnf',
                                        '--batch', '--skip-column-names', '-e', 'SELECT 1, @@GLOBAL.skip_networking'],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                if ready.returncode == 0 and ready.stdout.strip() == b'1\t0':
                    break
                time.sleep(2)
            else:
                raise RuntimeError('Isolated legacy database did not become ready')
            with (stage / 'registry.sql').open('wb') as stream:
                run('exec', '--user', '0:0', database, 'mysqldump', '--defaults-extra-file=/run/secrets/legacy.cnf',
                    '--single-transaction', '--skip-lock-tables', '--skip-triggers', '--no-tablespaces',
                    '--set-gtid-purged=OFF', 'iGEM2024', 'parts', stdout=stream)
            receipt = {'checkpoint_image': args.checkpoint_image, 'database_image': args.database_image,
                       'checkpoint_path': args.checkpoint_path, 'registry_tables': ['iGEM2024.parts'],
                       'imported_at_unix': time.time(), 'legacy_accounts_imported': False, 'files': {}}
            for name in ('160_model.pth', 'registry.sql'):
                asset = stage / name
                if not stat.S_ISREG(asset.lstat().st_mode) or not asset.stat().st_size:
                    raise RuntimeError(f'Imported {name} is empty or not a regular file')
                asset.chmod(0o600)
                receipt['files'][name] = hashlib.sha256(asset.read_bytes()).hexdigest()
            # Publish after both imports complete; no partial import is a success receipt.
            for name in ('160_model.pth', 'registry.sql'):
                os.replace(stage / name, args.output / name)
            receipt_path = args.output / 'import-receipt.json'
            receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
            receipt_path.chmod(0o600)
        finally:
            for container in reversed(containers):
                subprocess.run(['docker', 'rm', '-fv', container], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
