#!/usr/bin/env python3
"""Copy mounted operator inputs into private volumes owned by their consumers."""
import os
from pathlib import Path
import shutil
import tempfile


def prepare(source, destination, uid, gid):
    source, destination = Path(source), Path(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(str(destination.parent), uid, gid)
    os.chmod(str(destination.parent), 0o700)
    fd, temporary = tempfile.mkstemp(prefix='.prepare-', dir=str(destination.parent))
    try:
        with os.fdopen(fd, 'wb') as output, source.open('rb') as incoming:
            shutil.copyfileobj(incoming, output)
            output.flush()
            os.fsync(output.fileno())
            os.fchown(output.fileno(), uid, gid)
            os.fchmod(output.fileno(), 0o400)
        os.replace(temporary, str(destination))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    consumers = {
        'backend': (int(os.getenv('GCAI_UID', '10001')), int(os.getenv('GCAI_GID', '10001'))),
        'mysql': (int(os.getenv('GCAI_MYSQL_UID', '999')), int(os.getenv('GCAI_MYSQL_GID', '999'))),
        'proxy': (int(os.getenv('GCAI_NGINX_UID', '101')), int(os.getenv('GCAI_NGINX_GID', '101'))),
    }
    for consumer, name, source in [
        ('backend', 'db_app_password', '/run/secrets/db_app_password'),
        ('backend', '160_model.pth', '/input/160_model.pth'),
        ('mysql', 'db_app_password', '/run/secrets/db_app_password'),
        ('mysql', 'db_root_password', '/run/secrets/db_root_password'),
        ('mysql', 'registry.sql', '/input/registry.sql'),
    ]:
        prepare(source, '/prepared/' + consumer + '/' + name, *consumers[consumer])
    if os.getenv('GCAI_PREPARE_PROXY') == '1':
        for name in ('proxy_htpasswd', 'tls_certificate', 'tls_key'):
            prepare('/run/secrets/' + name, '/prepared/proxy/' + name, *consumers['proxy'])


if __name__ == '__main__':
    main()
