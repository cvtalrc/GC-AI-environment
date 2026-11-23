#!/bin/bash
# Sourced by the official MySQL image after 10-registry.sql on a NEW volume.
set -e
app_password=$(cat /run/gcai/db_app_password)
if [[ ! "$app_password" =~ ^[a-f0-9]{64}$ ]]; then
    echo 'Application password must be 64 lowercase hex characters' >&2
    exit 1
fi
# docker_process_sql is provided by the official MySQL entrypoint. Credentials
# enter through stdin and the secret mount, never command arguments.
docker_process_sql <<SQL
CREATE USER 'gcai'@'%' IDENTIFIED BY '$app_password';
GRANT SELECT ON \`iGEM2024\`.\`parts\` TO 'gcai'@'%';
SQL
unset app_password
