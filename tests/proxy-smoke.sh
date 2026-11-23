#!/bin/bash
# Exercise actual hosted topology/TLS/auth with a stdlib stub, no detector build.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/gcai-proxy-smoke.XXXXXX")
export COMPOSE_PROJECT_NAME="gcai-proxy-${GITHUB_RUN_ID:-$$}"
export GCAI_TRUSTED_ORIGINS=https://localhost
mkdir -m 700 "$workspace/secrets" "$workspace/assets" "$workspace/receipts"
cp "$repository"/compose*.yml "$workspace/"
cp -R "$repository/scripts" "$repository/nginx" "$workspace/"
cd "$workspace"
cat > sanitize.py <<'PY'
from pathlib import Path
import json,sys
values=[]
for name in ['db_root_password','db_app_password','basic_password','htpasswd','tls.key']:
    path=Path('secrets')/name
    if path.exists():
        value=path.read_text().strip()
        values.extend([value,json.dumps(value)[1:-1]])
        if name=='htpasswd':
            values.append(value.partition(':')[2])
        if name=='tls.key':
            values.extend(line for line in value.splitlines() if not line.startswith('-----'))
for name in sys.argv[1:]:
    path=Path(name)
    if path.exists():
        content=path.read_text(errors='replace')
        for value in sorted(set(values),key=len,reverse=True):
            if value:
                content=content.replace(value,'[REDACTED]')
        print('Sanitized diagnostic: '+path.name)
        print(content)
PY
compose=(docker compose -f compose.hosted.yml -f compose.probe.yml)
cleanup() {
    result=$?
    trap - EXIT
    set +e
    if [ "$result" -ne 0 ]; then
        "${compose[@]}" logs --no-color > receipts/services.log 2>&1
        proxy_id=$("${compose[@]}" ps -aq proxy)
        if [ -n "$proxy_id" ]; then
            docker inspect "$proxy_id" > receipts/proxy-failure.json 2>&1
        fi
        python3 sanitize.py receipts/up.log receipts/services.log receipts/proxy-failure.json receipts/curl.log
    fi
    "${compose[@]}" down -v --remove-orphans > receipts/cleanup.log 2>&1
    rm -rf "$workspace"
    exit "$result"
}
trap cleanup EXIT
python3 - <<'PY'
from pathlib import Path
import secrets,subprocess
for name in ['db_root_password','db_app_password','basic_password']:
    path=Path('secrets')/name
    path.write_text(secrets.token_hex(32)); path.chmod(0o600)
password=Path('secrets/basic_password').read_text()
hashed=subprocess.run(['openssl','passwd','-6','-stdin'],input=password,text=True,capture_output=True,check=True).stdout.strip()
Path('secrets/htpasswd').write_text('gcai:'+hashed+'\n')
Path('secrets/curl.conf').write_text('user = "gcai:'+password+'"\ncacert = "secrets/tls.crt"\n')
Path('secrets/htpasswd').chmod(0o600); Path('secrets/curl.conf').chmod(0o600)
Path('assets/160_model.pth').write_bytes(b'Proxy-only placeholder: never loaded')
Path('assets/registry.sql').write_text('CREATE TABLE parts (part_name VARCHAR(255) PRIMARY KEY); INSERT INTO parts VALUES ("ci-part");\n')
for path in Path('assets').iterdir(): path.chmod(0o600)
PY
openssl req -x509 -newkey rsa:2048 -nodes -keyout secrets/tls.key -out secrets/tls.crt -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
chmod 600 secrets/tls.*
cat > probe-server.py <<'PY'
from http.server import BaseHTTPRequestHandler,HTTPServer
import json,threading,time
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):
        pass
    def do_GET(self):
        status=200 if self.path in ('/livez','/stop-listening') else 404
        payload={'status':'alive','probe':'stdlib-stub'} if status==200 else {'error':'not_found'}
        body=json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if self.path=='/stop-listening':
            threading.Thread(target=self.server.shutdown,daemon=True).start()
server=HTTPServer(('0.0.0.0',5001),Handler)
server.serve_forever()
server.server_close()
# Retain the container network while the listener is closed, so connection
# refusal is immediate rather than depending on Docker ARP/route expiration.
time.sleep(600)
PY
chmod 644 probe-server.py
cat > compose.probe.yml <<'YAML'
services:
  backend:
    entrypoint: ['python', '/bootstrap/probe-server.py']
    command: []
    volumes:
      - ./probe-server.py:/bootstrap/probe-server.py:ro
  janitor:
    # This job checks proxy/auth/network only. Production janitor is tested separately.
    entrypoint: ['python']
    command: ['-c', 'import time; time.sleep(600)']
YAML
docker pull python:3.12-slim
docker pull nginx:1.28-alpine
docker pull mysql:8.4
export GCAI_BACKEND_IMAGE=$(docker image inspect python:3.12-slim --format '{{.Id}}')
export GCAI_FRONTEND_IMAGE=$(docker image inspect nginx:1.28-alpine --format '{{index .RepoDigests 0}}')
export GCAI_MYSQL_IMAGE=$(docker image inspect mysql:8.4 --format '{{index .RepoDigests 0}}')
export GCAI_MYSQL_UID=$(docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -u mysql)
export GCAI_MYSQL_GID=$(docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -g mysql)
export GCAI_NGINX_UID=$(docker run --rm --network none --entrypoint id "$GCAI_FRONTEND_IMAGE" -u nginx)
export GCAI_NGINX_GID=$(docker run --rm --network none --entrypoint id "$GCAI_FRONTEND_IMAGE" -g nginx)
"${compose[@]}" config --quiet
"${compose[@]}" up -d > receipts/up.log 2>&1
proxy_id=$("${compose[@]}" ps -q proxy)
docker inspect "$proxy_id" > receipts/proxy.json
python3 - <<'PY'
from pathlib import Path
import json
[proxy]=json.loads(Path('receipts/proxy.json').read_text())
assert proxy['NetworkSettings']['Ports'].get('443/tcp'), 'Docker did not publish actual TLS port'
assert len(proxy['NetworkSettings']['Networks'])==2
assert any(name.endswith('_edge') for name in proxy['NetworkSettings']['Networks'])
PY
deadline=$((SECONDS+60))
ready=false
while [ "$SECONDS" -lt "$deadline" ]; do
    if curl --config secrets/curl.conf --connect-timeout 2 --max-time 3 -fsS https://localhost/api/livez > receipts/live.json 2>receipts/curl.log; then
        ready=true; break
    fi
    sleep 1
done
[ "$ready" = true ]
for path in / /api/livez; do
    status=$(curl --cacert secrets/tls.crt --connect-timeout 2 --max-time 5 -sS -D receipts/unauth.headers -o /dev/null -w '%{http_code}' "https://localhost$path")
    [ "$status" = 401 ]
    python3 - <<'PY'
from pathlib import Path
assert 'www-authenticate: basic' in Path('receipts/unauth.headers').read_text().lower()
PY
done
curl --config secrets/curl.conf --connect-timeout 2 --max-time 5 -fsS https://localhost/ > receipts/frontend.html
python3 - <<'PY'
from pathlib import Path
import json
assert 'Welcome to nginx!' in Path('receipts/frontend.html').read_text()
assert json.loads(Path('receipts/live.json').read_text()) == {'status':'alive','probe':'stdlib-stub'}
PY
# Reject an oversized declared body without allocating/uploading a large fixture.
status=$(curl --config secrets/curl.conf --connect-timeout 2 --max-time 5 -sS \
 --request POST --header 'Content-Length: 12582913' --data-binary '' \
 --output receipts/too-large.json -w '%{http_code}' https://localhost/api/inference/)
[ "$status" = 413 ]
python3 - <<'PY'
from pathlib import Path
import json
body=json.loads(Path('receipts/too-large.json').read_text())
assert body['status_code']==413 and body['code']=='request_too_large'
PY
# The real proxy maps an unavailable upstream to the shared sanitized JSON contract.
curl --config secrets/curl.conf --connect-timeout 2 --max-time 5 -fsS https://localhost/api/stop-listening >/dev/null
sleep 1
status=$(curl --config secrets/curl.conf --connect-timeout 2 --max-time 5 -sS \
 --output receipts/unavailable.json -w '%{http_code}' https://localhost/api/livez)
[ "$status" = 503 ]
python3 - <<'PY'
from pathlib import Path
import json
body=json.loads(Path('receipts/unavailable.json').read_text())
assert body == {'status_code':503,'error':'Service is unavailable','code':'dependency_unavailable'}
PY
printf '%s\n' 'Hosted proxy smoke passed: actual published TLS port, unauthenticated401, authenticated frontend/API200, bounded413 and sanitized upstream503 (stdlib backend stub)'
