#!/bin/bash
# Fresh, disposable MySQL-only integration. No detector image or legacy assets.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/gcai-mysql-smoke.XXXXXX")
export COMPOSE_PROJECT_NAME="gcai-mysql-${GITHUB_RUN_ID:-$$}"
export GCAI_TRUSTED_ORIGINS=http://localhost:8081
export GCAI_FRONTEND_IMAGE=nginx:1.28-alpine
mkdir -m 700 "$workspace/secrets" "$workspace/assets" "$workspace/receipts"
cp "$repository"/compose*.yml "$repository/docker-compose.yml" "$workspace/"
cp -R "$repository/scripts" "$repository/nginx" "$workspace/"
cd "$workspace"
cat > sanitize.py <<'PY'
from pathlib import Path
import sys
secrets = [path.read_text().strip() for path in Path('secrets').glob('db_*_password')]
for name in sys.argv[1:]:
    path = Path(name)
    if not path.exists():
        continue
    content = path.read_text(errors='replace')
    for secret in sorted(secrets, key=len, reverse=True):
        if secret:
            content = content.replace(secret, '[REDACTED]')
    print('Sanitized diagnostic: ' + path.name)
    print(content)
PY
cleanup() {
    result=$?
    trap - EXIT
    set +e
    if [ "$result" -ne 0 ]; then
        docker compose logs --no-color db secret-init > receipts/services.log 2>&1
        db_id=$(docker compose ps -aq db)
        if [ -n "$db_id" ]; then
            docker inspect "$db_id" --format '{{json .State.Health}}' > receipts/health.log 2>&1
            docker inspect "$db_id" --format '{{json .Config.Healthcheck}}' > receipts/health-command.log 2>&1
        fi
        python3 sanitize.py receipts/up.log receipts/checks.log receipts/services.log receipts/health.log receipts/health-command.log
    fi
    docker compose down -v --remove-orphans > receipts/cleanup.log 2>&1
    rm -rf "$workspace"
    exit "$result"
}
trap cleanup EXIT
python3 - <<'PY'
from pathlib import Path
import secrets
for name in ('db_root_password','db_app_password'):
    path = Path('secrets') / name
    path.write_text(secrets.token_hex(32))
    path.chmod(0o600)
Path('assets/160_model.pth').write_bytes(b'MySQL-only placeholder: never loaded')
Path('assets/registry.sql').write_text(
    'CREATE TABLE parts (part_name VARCHAR(255) PRIMARY KEY, part_type VARCHAR(100), sequence TEXT);\n'
    'INSERT INTO parts VALUES ("ci-part","coding","atgc");\n'
)
for path in Path('assets').iterdir():
    path.chmod(0o600)
PY
# Python supplies only stdlib preparation; neither backend nor proxy is started.
docker pull python:3.12-slim
docker pull "${GCAI_MYSQL_TEST_IMAGE:-mysql:8.4}"
export GCAI_BACKEND_IMAGE=$(docker image inspect python:3.12-slim --format '{{.Id}}')
export GCAI_MYSQL_IMAGE=$(docker image inspect "${GCAI_MYSQL_TEST_IMAGE:-mysql:8.4}" --format '{{index .RepoDigests 0}}')
export GCAI_MYSQL_UID=$(docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -u mysql)
export GCAI_MYSQL_GID=$(docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -g mysql)
docker compose config --quiet
docker compose up -d db > receipts/up.log 2>&1
db_id=$(docker compose ps -q db)
health=starting
for attempt in $(seq 1 60); do
    health=$(docker inspect "$db_id" --format '{{.State.Health.Status}}')
    if [ "$health" = healthy ] || [ "$health" = unhealthy ]; then break; fi
    sleep 2
done
[ "$health" = healthy ]
# The exact production init scripts, mounted secrets and real MySQL grant boundary.
docker compose exec -T db sh -c '
 set -eu
 umask 077
 config=$(mktemp)
 trap '\''rm -f "$config"'\'' EXIT
 printf "[client]\nuser=root\npassword=%s\n" "$(cat /run/gcai/db_root_password)" > "$config"
 test "$(mysql --defaults-extra-file="$config" --batch --skip-column-names -e "SELECT 1")" = 1
 test "$(mysql --defaults-extra-file="$config" --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User=\"root\" AND Host<>\"localhost\"")" = 0
 printf "[client]\nuser=gcai\npassword=%s\n" "$(cat /run/gcai/db_app_password)" > "$config"
 test "$(mysql --defaults-extra-file="$config" --batch --skip-column-names iGEM2024 -e "SELECT COUNT(*) FROM parts")" = 1
 if mysql --defaults-extra-file="$config" iGEM2024 -e "INSERT INTO parts VALUES (\"forbidden\",\"coding\",\"a\")"; then exit 1; fi
' > receipts/checks.log 2>&1
printf '%s\n' 'MySQL-only smoke passed: imported registry, SELECT 1, SELECT-only application, no remote root'
