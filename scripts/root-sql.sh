#!/bin/sh
# Feed a private SQL file through stdin; credentials never appear in arguments.
set -eu
: "${1:?Usage: scripts/root-sql.sh private-input.sql}"
docker compose -f compose.hosted.yml exec -T db sh -c '
  set -eu
  umask 077
  config=$(mktemp)
  trap '\''rm -f "$config"'\'' EXIT HUP INT TERM
  printf "[client]\nuser=root\npassword=%s\n" "$(cat /run/gcai/db_root_password)" > "$config"
  mysql --defaults-extra-file="$config" iGEM2024
' < "$1"
