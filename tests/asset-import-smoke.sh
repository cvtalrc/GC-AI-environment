#!/bin/bash
# Synthetic pinned legacy fixtures only; no real checkpoint, credentials or GPU.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/gcai-asset-import.XXXXXX")
fixture_label="gcai-asset-import-${GITHUB_RUN_ID:-$$}"
registry_container=''
checkpoint_ref=''
database_ref=''
checkpoint_pin=''
database_pin=''
watcher=''
registry_existed=false
mysql_existed=false
if docker image inspect registry:2 >/dev/null 2>&1; then registry_existed=true; fi
if docker image inspect mysql:8.4 >/dev/null 2>&1; then mysql_existed=true; fi
mkdir -m 700 "$workspace/private" "$workspace/receipts" "$workspace/checkpoint-context" "$workspace/database-context"
cd "$workspace"
cat > sanitize.py <<'PY'
import configparser
from pathlib import Path
import sys
configuration = configparser.ConfigParser(interpolation=None)
configuration.read('private/legacy.cnf')
secret = configuration.get('client', 'password', fallback='')
for argument in sys.argv[1:]:
    path = Path(argument)
    if path.exists():
        contents = path.read_text(errors='replace')
        if secret:
            contents = contents.replace(secret, '[REDACTED]')
        print('Sanitized diagnostic: ' + path.name)
        print(contents)
PY
cleanup() {
    result=$?
    trap - EXIT
    set +e
    if [ -n "$watcher" ]; then kill "$watcher" >/dev/null 2>&1; wait "$watcher" >/dev/null 2>&1; fi
    if [ "$result" -ne 0 ]; then
        python3 sanitize.py receipts/import.log receipts/observed-database.json
    fi
    # Labels and names scope every removal to this disposable fixture run.
    for container in $(docker ps -aq --filter "label=org.gcai.fixture=$fixture_label"); do
        docker rm -fv "$container" >/dev/null 2>&1
    done
    if [ -n "$registry_container" ]; then docker rm -fv "$registry_container" >/dev/null 2>&1; fi
    for image in "$checkpoint_ref" "$database_ref" "$checkpoint_pin" "$database_pin"; do
        if [ -n "$image" ]; then docker image rm -f "$image" >/dev/null 2>&1; fi
    done
    if [ "$registry_existed" = false ]; then docker image rm registry:2 >/dev/null 2>&1; fi
    if [ "$mysql_existed" = false ]; then docker image rm mysql:8.4 >/dev/null 2>&1; fi
    rm -rf "$workspace"
    exit "$result"
}
trap cleanup EXIT
python3 - <<'PY'
from pathlib import Path
import secrets
secret = secrets.token_hex(32)
credentials = Path('private/legacy.cnf')
credentials.write_text('[client]\nuser=root\npassword=' + secret + '\n')
credentials.chmod(0o600)
Path('checkpoint-context/checkpoint.pth').write_bytes(b'GC-AI synthetic checkpoint fixture; never unpickle\n')
# The delay makes premature socket readiness fail before schema/data exist.
# A correct importer waits for the permanent network-enabled MySQL instance.
Path('database-context/10-fixture.sql').write_text(
    'SELECT SLEEP(5);\n'
    'CREATE TABLE parts (part_name VARCHAR(255) PRIMARY KEY, sequence TEXT);\n'
    'INSERT INTO parts VALUES ("ci_legacy_part_a","ATGC"),("ci_legacy_part_b","NNAA");\n'
)
# The entrypoint drops to mysql before reading fixture SQL from the image layer.
Path('database-context/10-fixture.sql').chmod(0o644)
PY
cat > checkpoint-context/Dockerfile <<'DOCKERFILE'
FROM scratch
ARG FIXTURE_LABEL
LABEL org.gcai.fixture=$FIXTURE_LABEL
COPY checkpoint.pth /checkpoint.pth
DOCKERFILE
cat > database-context/Dockerfile <<'DOCKERFILE'
ARG MYSQL_BASE
FROM ${MYSQL_BASE}
ARG FIXTURE_LABEL
LABEL org.gcai.fixture=$FIXTURE_LABEL
ENV MYSQL_DATABASE=iGEM2024
COPY 10-fixture.sql /docker-entrypoint-initdb.d/10-fixture.sql
DOCKERFILE
docker pull registry:2
docker pull mysql:8.4
mysql_base=$(docker image inspect mysql:8.4 --format '{{index .RepoDigests 0}}')
registry_container=$(docker run -d --network bridge -p 127.0.0.1::5000 --label "org.gcai.fixture=$fixture_label" registry:2)
registry_address=$(docker port "$registry_container" 5000/tcp)
[[ "$registry_address" == 127.0.0.1:* ]]
for attempt in $(seq 1 30); do
    if curl -fsS "http://$registry_address/v2/" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fsS "http://$registry_address/v2/" >/dev/null
checkpoint_ref="$registry_address/gcai-checkpoint:fixture"
database_ref="$registry_address/gcai-registry:fixture"
docker build --build-arg "FIXTURE_LABEL=$fixture_label" -t "$checkpoint_ref" checkpoint-context
docker build --build-arg "MYSQL_BASE=$mysql_base" --build-arg "FIXTURE_LABEL=$fixture_label" -t "$database_ref" database-context
docker push "$checkpoint_ref"
docker push "$database_ref"
checkpoint_pin=$(docker image inspect "$checkpoint_ref" --format '{{index .RepoDigests 0}}')
database_pin=$(docker image inspect "$database_ref" --format '{{index .RepoDigests 0}}')
[[ "$checkpoint_pin" == "$registry_address/gcai-checkpoint@sha256:"* ]]
[[ "$database_pin" == "$registry_address/gcai-registry@sha256:"* ]]
# Verify fixture images contain neither a baked password nor the private client file.
docker image inspect "$database_pin" --format '{{json .Config.Env}}' > receipts/fixture-environment.json
python3 - <<'PY'
import json
from pathlib import Path
values = json.loads(Path('receipts/fixture-environment.json').read_text())
assert 'MYSQL_DATABASE=iGEM2024' in values
assert not any('PASSWORD' in item.split('=',1)[0].upper() for item in values)
PY
docker volume ls -q | sort > receipts/volumes-before.txt
observe_database() {
    for attempt in $(seq 1 300); do
        container=$(docker ps -q --filter "ancestor=$database_pin")
        if [ -n "$container" ]; then
            docker inspect "$container" > receipts/observed-database.json
            return 0
        fi
        sleep 0.2
    done
    return 1
}
observe_database &
watcher=$!
python3 "$repository/scripts/import-assets.py" \
 --checkpoint-image "$checkpoint_pin" --checkpoint-path /checkpoint.pth \
 --database-image "$database_pin" --legacy-client-file "$workspace/private/legacy.cnf" \
 --output "$workspace/imported" > receipts/import.log 2>&1
wait "$watcher"
watcher=''
python3 - "$checkpoint_pin" "$database_pin" <<'PY'
import configparser,hashlib,json,re,stat,sys
from pathlib import Path
output = Path('imported')
assert sorted(path.name for path in output.iterdir()) == ['160_model.pth','import-receipt.json','registry.sql']
assert (output/'160_model.pth').read_bytes() == Path('checkpoint-context/checkpoint.pth').read_bytes()
receipt = json.loads((output/'import-receipt.json').read_text())
assert receipt['checkpoint_image'] == sys.argv[1]
assert receipt['database_image'] == sys.argv[2]
assert receipt['legacy_accounts_imported'] is False
assert receipt['registry_tables'] == ['iGEM2024.parts']
for name in ['160_model.pth','registry.sql']:
    path = output/name
    assert receipt['files'][name] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
credentials = configparser.ConfigParser(interpolation=None)
credentials.read('private/legacy.cnf')
assert stat.S_IMODE(Path('private/legacy.cnf').stat().st_mode) == 0o600
sql = (output/'registry.sql').read_text()
assert set(re.findall(r'CREATE TABLE\s+`([^`]+)`',sql,re.I)) == {'parts'}
assert not re.search(r'\bGRANT\b|\b(?:CREATE|ALTER)\s+USER\b|\b(?:mysql|sys|performance_schema|information_schema)\.',sql,re.I)
assert credentials.get('client','password') not in sql
assert all(value in sql for value in ['ci_legacy_part_a','ci_legacy_part_b','ATGC','NNAA'])
[observed] = json.loads(Path('receipts/observed-database.json').read_text())
assert observed['Config']['Image'] == sys.argv[2]
assert observed['HostConfig']['NetworkMode'] == 'none'
assert not observed['HostConfig']['PortBindings']
assert all(not bindings for bindings in (observed['NetworkSettings']['Ports'] or {}).values())
PY
# Importer must remove both containers, their anonymous volumes and staging secrets.
[ -z "$(docker ps -aq --filter "ancestor=$database_pin")" ]
[ -z "$(docker ps -aq --filter "ancestor=$checkpoint_pin")" ]
docker volume ls -q | sort > receipts/volumes-after.txt
diff receipts/volumes-before.txt receipts/volumes-after.txt
printf '%s\n' 'Synthetic asset import passed: pinned images, exact checkpoint/data, private isolated DB and complete cleanup'
