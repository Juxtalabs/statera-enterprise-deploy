#!/bin/sh
# Install Statera on this server — one command (Phase 31 WP8; enhancements E6,
# E3).
#
# Download the pinned, checksummed installer of a CLI release and run it:
#
#   curl -fsSL https://github.com/Juxtalabs/statera-enterprise-deploy/releases/download/v1.2.1/install.sh -o install.sh
#   curl -fsSL https://github.com/Juxtalabs/statera-enterprise-deploy/releases/download/v1.2.1/install.sh.sha256 -o install.sh.sha256
#   sha256sum --check install.sh.sha256
#   sudo sh install.sh --domain erp.example.co.id --release app-v1.2.0 \
#                     --entity-code PTABC --entity-name "PT Contoh Abadi" \
#                     --s3-bucket statera-backup-ptabc --s3-region ap-southeast-1 \
#                     --s3-access-key-id AKIAXXXXXXXXXXXXXXXX
#
# The activation code and the S3 secret are asked for (hidden) when they are
# not given as options, so they stay out of the shell history and `ps`.
#
# The bundle files and the App release manifest are downloaded from the same
# releases and verified against their checksums; the App image is pinned by
# digest, never by a moving tag.
#
# Options:
#   --domain <name>           the address users open (its DNS A record must point here)
#   --activation-code <code>  the one-time code from Juxtalabs (asked for when omitted)
#   --entity-code <code>      the first legal entity's code (max 20 characters)
#   --entity-name <name>      its name
#   --release <app-vX.Y.Z>    the App release to install (default: the one this CLI
#                             was released with, DEFAULT_APP_RELEASE below)
#   --self-update             refresh the bundle files only (`statera self-update`)
#   --no-proxy                another reverse proxy already serves 80/443 here: the App
#                             listens on 127.0.0.1:<port> and that proxy forwards to it
#   --port <n>                that loopback port (default 8000)
#   --proxy-network <name>    with --no-proxy, when that reverse proxy runs in Docker:
#                             the App also joins this existing Docker network, and the
#                             proxy forwards to http://statera-app-1:8000 (a containerised
#                             proxy cannot reach the host's 127.0.0.1)
#   --control-url <url>       Statera Control (default https://statera-control.juxtalabs.io;
#                             an explicit http:// URL is allowed for a local rehearsal)
#
# The offsite backup (enhancement E3, all of them together or none):
#   --s3-bucket <name>            the company's private bucket
#   --s3-region <region>          e.g. ap-southeast-1
#   --s3-access-key-id <id>       the IAM user Juxtalabs created for this company
#   --s3-secret-access-key <key>  its secret (asked for when omitted)
#   --s3-endpoint <host[:port]>   an S3-compatible endpoint (MinIO); AWS is the default
#
# Without the four S3 options the install has no offsite backup: nothing runs
# pgBackRest, `BACKUP_ARCHIVE_MODE=off` and no TLS server starts. With them,
# install.sh generates the repository cipher passphrase and the pgBackRest TLS
# certificates, then `statera install` creates the attachment age identity
# (its only copy goes to Juxtalabs' escrow), creates the stanza and takes the
# first full backup.
#
# Environment:
#   STATERA_RELEASE_BASE_URL      where this CLI release's assets are served
#                                 (default: its GitHub release page)
#   STATERA_APP_RELEASE_BASE_URL  where the App release manifest is served
#                                 (default: the App release's GitHub page)
#
# Needs Docker with the compose plugin and the commands curl, jq, sha256sum,
# flock and openssl, run as root. Installs to /opt/statera and the `statera`
# command to /usr/local/bin. Nothing here is secret: the images are private
# and pulled with a credential Control issues for the activation code.
set -eu

STATERA_CLI_VERSION=1.2.1
STATERA_REPOSITORY=Juxtalabs/statera-enterprise-deploy
RELEASE_BASE=${STATERA_RELEASE_BASE_URL:-https://github.com/$STATERA_REPOSITORY/releases/download/v$STATERA_CLI_VERSION}
DIR=${STATERA_DIR:-/opt/statera}
CONTROL=https://statera-control.juxtalabs.io
CONTROL_EXPLICIT=0
# The App release this CLI was published with; CLI and App versions move
# separately, so a CLI fix does not name an App release that does not exist.
DEFAULT_APP_RELEASE=app-v1.2.0
DOMAIN="" CODE="" ENTITY_CODE="" ENTITY_NAME="" PROXY=1 PORT=8000 PROXY_NETWORK=""
APP_RELEASE=$DEFAULT_APP_RELEASE SELF_UPDATE=0
S3_BUCKET="" S3_REGION="" S3_ACCESS="" S3_SECRET="" S3_ENDPOINT=""

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '== %s\n' "$*"; }

# Read a secret from the terminal without echoing it; the value goes to
# stdout. Without a terminal the option has to be given instead.
ask_secret() {
  [ -t 0 ] || die "$1 is missing: give it as an option when not running in a terminal"
  printf '%s (hidden): ' "$1" >&2
  stty -echo
  trap 'stty echo' EXIT INT TERM
  IFS= read -r _secret || _secret=""
  stty echo
  trap - EXIT INT TERM
  printf '\n' >&2
  printf '%s' "$_secret"
}

# Download one asset. https only, except an explicit http base — which exists
# solely so a local HTTP server can rehearse a release end to end through
# STATERA_RELEASE_BASE_URL / STATERA_APP_RELEASE_BASE_URL.
fetch() {
  case "$1" in
    https://*) curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2" ;;
    http://*) curl --proto '=http' -fsSL "$1" -o "$2" ;;
    *) return 1 ;;
  esac
}

# A call to Statera Control. https only — except when --control-url was given
# explicitly, which is how a local plain-http Control is rehearsed; the same
# rule fetch() applies to an explicit http base URL.
control_fetch() {
  if [ "$CONTROL_EXPLICIT" = 1 ]; then
    curl -fsS "$@"
  else
    curl --proto '=https' --tlsv1.2 -fsS "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=$2; shift 2 ;;
    --activation-code) CODE=$2; shift 2 ;;
    --entity-code) ENTITY_CODE=$2; shift 2 ;;
    --entity-name) ENTITY_NAME=$2; shift 2 ;;
    --release) APP_RELEASE=$2; shift 2 ;;
    --self-update) SELF_UPDATE=1; shift ;;
    --no-proxy) PROXY=0; shift ;;
    --port) PORT=$2; shift 2 ;;
    --proxy-network) PROXY_NETWORK=$2; shift 2 ;;
    --control-url) CONTROL=$2; CONTROL_EXPLICIT=1; shift 2 ;;
    --s3-bucket) S3_BUCKET=$2; shift 2 ;;
    --s3-region) S3_REGION=$2; shift 2 ;;
    --s3-access-key-id) S3_ACCESS=$2; shift 2 ;;
    --s3-secret-access-key) S3_SECRET=$2; shift 2 ;;
    --s3-endpoint) S3_ENDPOINT=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
if [ "$CONTROL_EXPLICIT" = 1 ]; then
  case "$CONTROL" in
    https://* | http://*) ;;
    *) die "--control-url must be an http(s) URL: $CONTROL" ;;
  esac
fi
# The offsite backup is all four settings or none: a half-configured bucket
# is a backup that fails at 01:00, months from now.
OFFSITE=0
if [ -n "$S3_BUCKET$S3_REGION$S3_ACCESS$S3_SECRET$S3_ENDPOINT" ]; then
  OFFSITE=1
  [ -n "$S3_BUCKET" ] && [ -n "$S3_REGION" ] && [ -n "$S3_ACCESS" ] \
    || die "--s3-bucket, --s3-region and --s3-access-key-id go together (the secret is asked for)"
fi

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -s)" = Linux ] || die "Statera runs on Linux"
case "$(uname -m)" in
  x86_64 | amd64) ;;
  *) die "Statera supports x86-64 Linux only (this is $(uname -m))" ;;
esac
for command in curl jq sha256sum flock openssl awk sed grep sort df docker; do
  command -v "$command" >/dev/null 2>&1 || die "required command is missing: $command"
done

if [ "$SELF_UPDATE" = 0 ]; then
  [ -n "$DOMAIN" ] && [ -n "$ENTITY_CODE" ] && [ -n "$ENTITY_NAME" ] \
    || die "--domain, --entity-code and --entity-name are required"
  [ -n "$CODE" ] || CODE=$(ask_secret "Activation code")
  [ -n "$CODE" ] || die "the activation code is required"
  if [ "$OFFSITE" = 1 ] && [ -z "$S3_SECRET" ]; then
    S3_SECRET=$(ask_secret "S3 secret access key")
    [ -n "$S3_SECRET" ] || die "the S3 secret access key is required with --s3-bucket"
  fi
  docker info >/dev/null 2>&1 || die "Docker Engine is not running or is not accessible"
  docker compose version >/dev/null 2>&1 || die "the Docker compose plugin is not installed"
  if [ -n "$PROXY_NETWORK" ]; then
    [ "$PROXY" = 0 ] || die "--proxy-network goes with --no-proxy"
    docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 \
      || die "the Docker network $PROXY_NETWORK does not exist (it is the reverse proxy's network)"
  fi
fi

mkdir -p "$DIR"
chmod 750 "$DIR"
umask 077
exec 9>"$DIR/.statera.lock"
flock -n 9 || die "another Statera operation is already running on this server"

if [ "$SELF_UPDATE" = 0 ] && [ -f "$DIR/state/current-release" ]; then
  die "$DIR/state/current-release exists: Statera is already installed — use statera update, or statera self-update for a newer CLI"
fi
RESUME=0
if [ "$SELF_UPDATE" = 0 ] && [ -f "$DIR/.env" ]; then
  RESUME=1
  note "resuming the incomplete installation with the existing $DIR/.env"
fi

# Refuse to adopt anything that looks like another Statera project. Skipped on
# a resume: the partial run's own project, volumes and network are the point.
preflight_new_install() {
  docker compose ls --format json | jq -e '.[] | select(.Name == "statera")' >/dev/null 2>&1 \
    && die "a Docker Compose project named statera already exists — Statera will not adopt it"
  for volume in statera_pgdata statera_keys statera_attachments statera_backups statera_pgbackrest-spool statera_caddy-data statera_caddy-config; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      die "Docker volume $volume already exists — Statera will not adopt it"
    fi
  done
  if docker network inspect statera_default >/dev/null 2>&1; then
    die "Docker network statera_default already exists — Statera will not adopt it"
  fi
  check_port "$PORT" "the App's loopback"
  if [ "$PROXY" = 1 ]; then
    check_port 80 "Caddy"
    check_port 443 "Caddy"
  fi
}

# A listening socket on `port` is a conflict. `ss` is consulted when present
# (it is not in the required set), otherwise compose reports the clash itself.
check_port() {
  command -v ss >/dev/null 2>&1 || return 0
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])$1\$"; then
    die "$2 port $1 is already in use on this host"
  fi
}

if [ "$SELF_UPDATE" = 0 ]; then
  avail=$(df -Pk "$DIR" | awk 'NR == 2 {print $4}')
  case "$avail" in
    '' | *[!0-9]*) die "could not read the free disk space of $DIR" ;;
  esac
  [ "$avail" -ge 5242880 ] \
    || die "at least 5 GiB free is required before install ($DIR has $((avail / 1024)) MiB)"
  if [ "$RESUME" = 0 ]; then
    preflight_new_install
  fi
fi

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT HUP INT TERM

# The pgBackRest TLS certificates (E3): a CA, a server certificate for the
# `postgres` service name (the name the App connects to, compared against the
# certificate) and a client certificate for the App. Written once, next to
# `.env`, mounted read-only into both containers; the PostgreSQL container
# copies them to a writable place and gives the key to its `postgres` user.
write_pgbackrest_certs() {
  dir="$DIR/pgbackrest"
  [ -s "$dir/server.crt" ] && return 0
  mkdir -p "$dir"
  # Traverse-only: the container's `postgres` user must reach the certificates
  # and the pgBackRest default config path through this mount; the keys
  # themselves stay 600 root.
  chmod 711 "$dir"
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=statera-ca" \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" >/dev/null 2>&1
  printf 'subjectAltName=DNS:postgres\n' >"$tmp/server-ext.cnf"
  openssl req -new -nodes -subj "/CN=postgres" \
    -keyout "$dir/server.key" -out "$dir/server.csr" >/dev/null 2>&1
  openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -CAcreateserial -days 3650 -extfile "$tmp/server-ext.cnf" \
    -out "$dir/server.crt" >/dev/null 2>&1
  openssl req -new -nodes -subj "/CN=statera-client" \
    -keyout "$dir/client.key" -out "$dir/client.csr" >/dev/null 2>&1
  openssl x509 -req -in "$dir/client.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -CAcreateserial -days 3650 -out "$dir/client.crt" >/dev/null 2>&1
  rm -f "$dir"/*.csr "$dir"/*.srl
  chmod 600 "$dir"/*.key
  chmod 644 "$dir"/*.crt
}

# The bundle: downloaded to a scratch directory, verified against the release's
# SHA256SUMS, then installed. lib.sh is verified with the two commands that
# exist before it can be sourced; every file is re-verified through it after.
set -- lib.sh statera update.sh updater.sh docker-compose.yml Caddyfile release.schema.json
note "downloading the bundle (CLI $STATERA_CLI_VERSION)"
fetch "$RELEASE_BASE/SHA256SUMS" "$tmp/SHA256SUMS" \
  || die "could not download SHA256SUMS from $RELEASE_BASE"
for file in "$@"; do
  fetch "$RELEASE_BASE/$file" "$tmp/$file" \
    || die "could not download $file from $RELEASE_BASE"
done
expected=$(awk -v asset=lib.sh '$2 == asset || $2 == "*" asset {print $1; exit}' "$tmp/SHA256SUMS")
actual=$(sha256sum "$tmp/lib.sh" | awk '{print $1}')
[ -n "$expected" ] && [ "$actual" = "$expected" ] || die "checksum mismatch for lib.sh"
# shellcheck source=/dev/null
. "$tmp/lib.sh"
for file in "$@"; do
  statera_verify_against_sums "$tmp/$file" "$file" "$tmp/SHA256SUMS"
done
for file in "$@"; do
  cp "$tmp/$file" "$DIR/$file"
done
chmod 755 "$DIR/statera" "$DIR/update.sh" "$DIR/updater.sh"
chmod 644 "$DIR/Caddyfile" "$DIR/docker-compose.yml" "$DIR/release.schema.json" "$DIR/lib.sh"
ln -sf "$DIR/statera" /usr/local/bin/statera

if [ "$SELF_UPDATE" = 1 ]; then
  printf 'statera %s is installed at %s.\n' "$STATERA_CLI_VERSION" "$DIR/statera"
  exit 0
fi

APP_RELEASE=$(statera_normalize_app_release "$APP_RELEASE")
case "$APP_RELEASE" in
  app-v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "--release takes an App release like app-v1.1.0" ;;
esac
APP_BASE=${STATERA_APP_RELEASE_BASE_URL:-https://github.com/$STATERA_REPOSITORY/releases/download/$APP_RELEASE}
note "the release manifest for $APP_RELEASE"
manifest=$(statera_fetch_manifest "$APP_RELEASE" "$APP_BASE" "$STATERA_CLI_VERSION" "$tmp")
APP_IMAGE=$(statera_manifest_value "$manifest" app_image)
POSTGRES_IMAGE=$(statera_manifest_value "$manifest" postgres_image)
MIGRATION_HEAD=$(statera_manifest_value "$manifest" migration_head)

# docker-compose.proxy.yml exists when install.sh was given --proxy-network: it
# joins the App to an existing reverse proxy's Docker network.
compose() {
  if [ -f "$DIR/docker-compose.proxy.yml" ]; then
    docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" -f "$DIR/docker-compose.proxy.yml" "$@"
  else
    docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"
  fi
}

if [ -n "$PROXY_NETWORK" ]; then
  cat >"$DIR/docker-compose.proxy.yml" <<EOF
# Written by install.sh --proxy-network: the App also joins the existing
# reverse proxy's Docker network, which forwards to http://statera-app-1:8000.
services:
  app:
    networks: [default, proxy]
networks:
  proxy:
    name: $PROXY_NETWORK
    external: true
EOF
fi

note "the image credential from Statera Control"
registry=$(control_fetch -X POST "$CONTROL/v1/registry" \
  -H 'content-type: application/json' -d "{\"activation_code\":\"$CODE\"}" 2>/dev/null) || registry=""
if [ -n "$registry" ]; then
  server=$(printf '%s' "$registry" | jq -r .server)
  username=$(printf '%s' "$registry" | jq -r .username)
  printf '%s' "$registry" | jq -r .token \
    | docker login "$server" -u "$username" --password-stdin >/dev/null \
    || die "the registry refused the credential Statera Control issued"
else
  # A resumed run after activation: the code is spent, but the App it
  # activated can ask Control with its sync key.
  if compose run --rm --no-deps -T app test -s /etc/statera/keys.json >/dev/null 2>&1; then
    credential=$(compose run --rm --no-deps -T app statera registry-credential) \
      || die "the App could not reach Statera Control for the registry credential"
    server=$(printf '%s\n' "$credential" | sed -n 1p)
    username=$(printf '%s\n' "$credential" | sed -n 2p)
    printf '%s\n' "$credential" | sed -n 3p \
      | docker login "$server" -u "$username" --password-stdin >/dev/null \
      || die "the registry refused the credential Statera Control issued"
  else
    die "Statera Control refused the activation code"
  fi
fi

if [ "$RESUME" = 0 ]; then
  note "writing $DIR/.env"
  ADMIN_PASSWORD=$(openssl rand -hex 16)
  cat >"$DIR/.env" <<EOF
# Written by install.sh (Statera CLI $STATERA_CLI_VERSION). Secrets: readable by root only.
STATERA_RELEASE=$APP_RELEASE
STATERA_IMAGE=$APP_IMAGE
STATERA_POSTGRES_IMAGE=$POSTGRES_IMAGE
STATERA_DOMAIN=$DOMAIN
STATERA_APP_PORT=$PORT
COMPOSE_PROFILES=$([ "$PROXY" = 1 ] && echo proxy)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
ENVIRONMENT=production
JWT_SECRET=$(openssl rand -hex 32)
SEED_ADMIN_PASSWORD=$ADMIN_PASSWORD
SEED_LEGAL_ENTITY_CODE=$ENTITY_CODE
SEED_LEGAL_ENTITY_NAME=$ENTITY_NAME
PASSKEY_RP_ID=$DOMAIN
PASSKEY_RP_NAME=Statera
PASSKEY_EXPECTED_ORIGIN=https://$DOMAIN
CORS_ORIGINS=https://$DOMAIN
STATERA_CONTROL_URL=$CONTROL
TEXT_PROVIDER=local
VISION_PROVIDER=local
LOCAL_AI_BASE_URL=$CONTROL/v1/ai
LOCAL_TEXT_MODEL=statera-text
LOCAL_VISION_MODEL=statera-vision
TZ=Asia/Jakarta
EOF
  if [ "$OFFSITE" = 1 ]; then
    cat >>"$DIR/.env" <<EOF
# The offsite backup (E3). BACKUP_ENABLED turns on after the repository is
# initialised below; BACKUP_ARCHIVE_MODE must stay 'on' while it is true.
BACKUP_ENABLED=false
BACKUP_ARCHIVE_MODE=on
BACKUP_S3_BUCKET=$S3_BUCKET
BACKUP_S3_REGION=$S3_REGION
BACKUP_S3_ENDPOINT=$S3_ENDPOINT
BACKUP_S3_ACCESS_KEY_ID=$S3_ACCESS
BACKUP_S3_SECRET_ACCESS_KEY=$S3_SECRET
BACKUP_DB_CIPHER_PASS=$(openssl rand -hex 32)
EOF
  else
    printf 'BACKUP_ENABLED=false\nBACKUP_ARCHIVE_MODE=off\n' >>"$DIR/.env"
  fi
  chmod 600 "$DIR/.env"
else
  statera_set_env "$DIR/.env" STATERA_RELEASE "$APP_RELEASE"
  statera_set_env "$DIR/.env" STATERA_IMAGE "$APP_IMAGE"
  statera_set_env "$DIR/.env" STATERA_POSTGRES_IMAGE "$POSTGRES_IMAGE"
  ADMIN_PASSWORD=$(sed -n 's/^SEED_ADMIN_PASSWORD=//p' "$DIR/.env")
fi

if [ "$OFFSITE" = 1 ]; then
  note "generating the pgBackRest TLS certificates"
  write_pgbackrest_certs
fi

note "pulling $APP_RELEASE"
compose pull
compose up -d postgres

if compose run --rm --no-deps -T app test -s /etc/statera/keys.json >/dev/null 2>&1; then
  note "activation is already done; continuing"
else
  note "installing: keys, database, activation"
  compose run --rm -T app statera install --activation-code "$CODE"
fi
if ! grep -q '^LOCAL_AI_API_KEY=' "$DIR/.env"; then
  printf 'LOCAL_AI_API_KEY=%s\n' "$(compose run --rm --no-deps -T app statera ai-credential)" >>"$DIR/.env"
fi

# The offsite backup (E3): the attachment recipient the App generated at
# install, then the stanza and the first full backup. Only once it exists is
# the daily job switched on.
if grep -q '^BACKUP_S3_BUCKET=.' "$DIR/.env"; then
  if ! grep -q '^BACKUP_ATTACHMENTS_RECIPIENT=.' "$DIR/.env"; then
    recipient=$(compose run --rm --no-deps -T app statera offsite-backup recipient) \
      || die "the App could not report its attachment recipient"
    statera_set_env "$DIR/.env" BACKUP_ATTACHMENTS_RECIPIENT "$recipient"
  fi
  note "creating the pgBackRest stanza and the first full backup"
  compose run --rm --no-deps -T app statera offsite-backup init \
    || die "the offsite backup could not be initialised — fix the BACKUP_* settings in $DIR/.env and rerun this installer"
  statera_set_env "$DIR/.env" BACKUP_ENABLED true
fi

compose up -d

note "waiting for the App to pass its health check"
healthy=0
tries=0
while [ $tries -lt 36 ]; do
  if compose exec -T app statera health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  tries=$((tries + 1))
  sleep 5
done
[ "$healthy" = 1 ] \
  || die "the App did not pass its health check — inspect: docker compose -f $DIR/docker-compose.yml logs app"

actual=$(compose exec -T app statera db head 2>/dev/null | tr -d '\r\n ')
if [ "$actual" != "$MIGRATION_HEAD" ]; then
  die "the database is at '${actual:-unknown}' but $APP_RELEASE declares the migration head $MIGRATION_HEAD"
fi

mkdir -p "$DIR/state"
printf '%s\n' "$APP_RELEASE" >"$DIR/state/current-release"
printf '%s\n' "$MIGRATION_HEAD" >"$DIR/state/current-migration"
chmod 600 "$DIR/state/current-release" "$DIR/state/current-migration"
statera_record_operation "$DIR/state" install "$APP_RELEASE" succeeded

if [ "$PROXY" = 1 ]; then
  proxy_target="Caddy (HTTPS on this server)"
elif [ -n "$PROXY_NETWORK" ]; then
  proxy_target="http://statera-app-1:8000 on the Docker network $PROXY_NETWORK"
else
  proxy_target="http://127.0.0.1:$PORT"
fi

cat <<EOF

Statera $APP_RELEASE is installed (database at $MIGRATION_HEAD).

  Open        https://$DOMAIN
  Proxy to    $proxy_target
  Sign in as  admin
  Password    $ADMIN_PASSWORD   (shown once — the first sign-in sets up a passkey)

  statera version                  this CLI and the installed App release
  statera doctor                   check the installation
  statera backup                   take a backup now
  statera update                   install a newer release when one is offered
  sudo statera self-update vX.Y.Z  update this CLI/bundle when a newer one is offered

Back up the key file somewhere safe (it decrypts the data and the backups):
  docker compose -f $DIR/docker-compose.yml exec app cat /etc/statera/keys.json
EOF