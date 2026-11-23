# GC-AI deployment

This repository coordinates the Epic #7 server/client release with a fresh MySQL
8.4 deployment. It replaces the legacy public database/root-account setup.
Hosted deployment publishes only HTTPS; the React frontend and `/api/` share one
origin and one Nginx Basic-authentication boundary. A trusted workspace shares
its generated-document handles. Treat handles as credentials until their fixed
24-hour expiry.

## Prerequisites and release inputs

Use Docker Engine and Compose supporting `include` and `extends`. The reviewed runtime lock targets Linux/amd64. Build the
reviewed GC-AI source with its backend and frontend Dockerfiles, publish those
images, and record immutable image digests and source revision. Do not use the
old application images to serve traffic. Copy `.env.example` to `.env` and replace
all placeholders with reviewed image digests; MySQL must be an 8.4 image. Pin the
legacy images separately when importing assets. No digest is invented here.

The backend image uses UID/GID 10001 by default; `GCAI_UID`/`GCAI_GID` can override
this. Verify the MySQL and Nginx numeric identities in the actual pinned images
before deployment, and put them in `.env` (`GCAI_MYSQL_UID`/`GCAI_MYSQL_GID`,
`GCAI_NGINX_UID`/`GCAI_NGINX_GID`). Defaults are 999:999 for MySQL and 101:101 for
Nginx. Verify without starting either application, for example:

```sh
docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -u mysql
docker run --rm --network none --entrypoint id "$GCAI_MYSQL_IMAGE" -g mysql
docker run --rm --network none --entrypoint id "$GCAI_FRONTEND_IMAGE" -u nginx
docker run --rm --network none --entrypoint id "$GCAI_FRONTEND_IMAGE" -g nginx
```

The backend command uses one Gunicorn worker, four threads, no preloading, and a
single inference admission slot. The proxy permits at most four active API
connections, limits requests to 12 MiB, and waits at most 180 seconds for a
response. Proxy and threaded-worker timeouts do **not** cancel GPU execution;
restart the worker after a sustained hang. [Gunicorn timeout semantics](https://gunicorn.org/reference/settings/#timeout).

## Import legacy assets into new storage

Create an operator-only `secrets/` directory with mode 0700. Put legacy database
credentials in a 0600 file **outside version control**:

```ini
[client]
user=root
password=the-existing-legacy-password
```

Determine the checkpoint's absolute path by inspecting/exporting the pinned
legacy image. The importer creates a stopped checkpoint container and copies
only that file; it never executes its application or unpickles its checkpoint.
It starts the legacy **database** image on `--network none`, publishes no ports,
and dumps only `iGEM2024.parts` schema/data. The original client credentials stay
0600 and are read only by explicit root client processes inside that container.
For the official entrypoint's drop to the mysql UID, the importer creates an
additional ephemeral root-password file with mode 0444 inside a private 0700
host staging directory. Only this isolated legacy database receives that
file-only read-only mount; the host parent prevents access by other local users.
The temporary file is removed on success or failure after the container is
removed. This scoped readability does not apply to deployed credentials, which
use the separate consumer-owned 0400 volumes described below. It removes
temporary containers and volumes on completion or failure. Readiness waits until the final server reports `skip_networking=0`; the official temporary initialization server must not be mistaken for a completed registry import. The legacy image must start a network-enabled final MySQL server (the container itself remains isolated on `--network none`). Review the legacy image's database entrypoint
and checkpoint provenance before running:

```sh
python3 scripts/import-assets.py \
  --checkpoint-image 'legacy/backend@sha256:VERIFIED_DIGEST' \
  --checkpoint-path /verified/absolute/path/160_model.pth \
  --database-image 'legacy/database@sha256:VERIFIED_DIGEST' \
  --legacy-client-file /private/operator/legacy-client.cnf
```

The importer rejects mutable tags. It writes private `assets/160_model.pth`,
`assets/registry.sql`, and an import receipt with digests and hashes. Inspect the
SQL before use: it must contain only the registry table, with no user/grant or
system-database statements. Never mount an existing legacy data volume into
MySQL 8.4; initialize `registry84` from this SQL. This imports no legacy accounts.
The checkpoint is trusted executable pickle input to Torch; digest provenance
and operator review remain required.

## Provision new credentials and TLS

Generate distinct new root/application secrets, without printing them:

```sh
mkdir -m 700 secrets
python3 - <<'PY'
from pathlib import Path
import secrets
for name in ('db_root_password', 'db_app_password'):
    path = Path('secrets') / name
    with path.open('x') as stream:
        stream.write(secrets.token_hex(32))
    path.chmod(0o600)
PY
htpasswd -B -c secrets/htpasswd gcai
chmod 600 secrets/htpasswd
```

`htpasswd` prompts interactively; do not pass a password as an argument. Store the
TLS certificate and private key in `secrets/tls.crt` and `secrets/tls.key` with
mode 0600; use a certificate trusted by the clients. Basic authentication applies
to both frontend and API. Nginx reads a mounted password-hash file. See the
[Nginx authentication reference](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html).
Credentials never belong in URLs, React build variables, or logs.

Local Compose bind mounts preserve host ownership. Keep all operator input files
0600 inside private 0700 host directories; no host ownership changes or
world-readable secrets are required. A root, network-isolated one-shot
`secret-init` service reads those mounted inputs and atomically copies each into
a separate private volume for its consumer. Volume directories are 0700; files
are 0400 and owned by the configured consumer UID/GID. Backend, MySQL and proxy
mount only their respective prepared volumes **read-only**. The checkpoint is
included in the backend's private read-only volume. The proxy volume permits the
Nginx worker to read its htpasswd; MySQL's volume permits its dropped mysql user
to read registry SQL and application credentials. TLS files are private to the
proxy. These additional secret copies persist in Docker volumes: encrypt and
protect Docker's storage, include them in the rotation/retirement procedure, and
never attach those volumes to unrelated containers.

MySQL's registry-import and account-init scripts are **non-executable** `.sh`
files, so the official entrypoint sources them with `docker_process_sql`
available. `MYSQL_ROOT_HOST=localhost` prevents creation of a remote root account.
The separate artifact-init service sets only the artifact-volume root to the
backend UID and 0700; backend and hourly network-isolated janitor share it.

## Start and verify

Set `GCAI_TRUSTED_ORIGINS=https://your-hostname` in `.env`. Supply the exact scheme,
host, and port served by the proxy. The backend rejects untrusted browser origins
on unsafe requests, including image uploads.

```sh
docker compose -f compose.hosted.yml config --quiet
docker compose -f compose.hosted.yml up -d
```

The new database imports registry SQL and grants `gcai` only SELECT on
`iGEM2024.parts`. No host port exists for backend or database. The only hosted
port is 443. The proxy alone joins a normal `edge` bridge so Docker can publish
its port, plus the private application network. Backend and database remain on
internal networks, with no host ports or edge attachment. Never combine the
local and hosted files: each includes shared
services independently. Review rendered Compose before starting.

For local development, set `GCAI_TRUSTED_ORIGINS=http://localhost:8081` and run
`docker compose up -d`; only `127.0.0.1:8081` is published. Set `GCAI_URL=http://localhost:8081/api` for the Python client, CLI and MCP. Local mode still
requires database secrets and imported assets; it does not require TLS/htpasswd
inputs. Local HTTP has no authentication and is intended solely for the local workstation.

Verify unauthenticated `/` and `/api/livez` return 401 with `WWW-Authenticate`,
then authenticate using a private curl configuration file or interactive
`curl --user gcai` prompt. Never pass `user:password` in the command line. Verify
`/api/healthcheck/` returns healthy 200 only after real detector initialization
and `SELECT 1` fetch; degraded dependencies return sanitized 503. `/api/livez`
checks the process independently. Exercise image inference with a real trusted
checkpoint, create→convert each requested format, SDK/CLI/MCP authentication,
and frontend conversion retry. Record source revisions, runtime image digests,
checksums, test results and operator identity in a private execution receipt.

`python3 -m unittest discover -s tests -v` checks the daemon-independent rendered
configuration. The manual Docker CI job accepts an exact reviewed GC-AI source
revision and exercises TLS authentication, fresh database migration, least
privileges, HTTP routes, backup/restore, and artifact cleanup. A passing mocked
inference test does not establish checkpoint/GPU readiness.

Before hosted cutover, stop the old public GC-AI containers in their original Compose project while retaining its volumes for rollback. Verify that its backend and database port mappings are gone; a new isolated project does not remove services belonging to another project. Only the new TLS proxy should publish a port for GC-AI. Record this check in the operator receipt.

## Backup and restore

```sh
scripts/backup.sh /private/backups/registry-YYYYMMDD.sql
```

The dump contains only registry schema/data and excludes accounts. Back up the
private checkpoint, import receipt, release manifest, TLS material and secret
files separately using encrypted operator-controlled storage. Generated
artifacts expire after 24 hours; back them up only if that retention policy is
intended. Keep the same absolute expiry metadata when restoring them.

For a live registry restore, stop backend and janitor, retain a tested backup,
review the dump, and run `scripts/root-sql.sh /private/backups/registry.sql`.
Restart services and verify readiness and read-only grants. To recover into fresh
storage, use a **new Compose project name**, copy the reviewed dump to
`assets/registry.sql`, provision new secrets and start the stack; inspect it
before changing traffic. Preserve the original volumes until recovery succeeds.
Never use `down -v` as a routine restart or migration command.

## Rotate credentials

An operator must execute and record rotation; code changes are insufficient.

1. Prepare new independent 64-character lowercase-hex root/application secrets
   in private files. Keep the old files available for rollback until verified.
2. Stop backend traffic. In a mode-0600 private SQL file prepare `ALTER USER
   'gcai'@'%' IDENTIFIED BY '<new-app-secret>';` and `ALTER USER 'root'@'localhost'
   IDENTIFIED BY '<new-root-secret>';`. Do not put this SQL in shell arguments,
   command history, tickets, receipts, or logs.
3. Feed that file through `scripts/root-sql.sh /private/rotation.sql`, then replace
   both private host source secret files, retaining 0600 and private parent
   directories. Run `docker compose -f compose.hosted.yml run --rm secret-init`
   to refresh all consumer copies, then recreate database and backend containers
   so the backend's import-time database configuration uses the new credentials.
   Do not reinitialize or remove the database volume.
4. Replace the mounted htpasswd using an interactive `htpasswd -B` command,
   preserving existing users as intended. Rerun `secret-init` to refresh the
   proxy's private copy, then recreate the proxy. Revoke the previous
   account/password after authenticated access is verified.
5. Check readiness, deny old credentials, verify new credentials with SDK/MCP,
   and run `SHOW GRANTS FOR 'gcai'@'%'` through a private operator SQL file. Securely
   remove temporary plaintext SQL and revoke legacy credentials only after the
   replacement deployment is accepted. Record no secret values in the receipt.

## Completion gate

This repository and the Epic #7 deployment child remain open until the two
reviewed source releases are coordinated and an operator accepts the environment
PR, Docker smoke evidence, real checkpoint/GPU readiness where deployed, asset
import receipt, and actual credential-rotation receipt. The implementation
session had no Docker daemon: no production migration or rotation is claimed.
