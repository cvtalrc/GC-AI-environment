#!/bin/sh
# Run from the repository root. Output is private and excludes MySQL accounts.
set -eu
umask 077
: "${1:?Usage: scripts/backup.sh private-output.sql}"
if [ -e "$1" ]; then echo 'Choose a new backup path' >&2; exit 1; fi
temporary=$(mktemp "${1}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
docker compose -f compose.hosted.yml exec -T db sh -c '
  set -eu
  umask 077
  config=$(mktemp)
  trap '\''rm -f "$config"'\'' EXIT HUP INT TERM
  printf "[client]\nuser=root\npassword=%s\n" "$(cat /run/gcai/db_root_password)" > "$config"
  mysqldump --defaults-extra-file="$config" --single-transaction --skip-lock-tables --skip-triggers --no-tablespaces --set-gtid-purged=OFF iGEM2024 parts
' > "$temporary"
test -s "$temporary"
mv "$temporary" "$1"
