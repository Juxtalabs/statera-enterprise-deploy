#!/bin/sh
# statera update [--to app-vX.Y.Z]  (Phase 31 WP6/WP8; enhancement E6)
#
# The App release is pinned by manifest: download app-vX.Y.Z.json + .sha256
# from the release's assets, verify the checksum and the shape (release.schema
# .json), refuse a release that needs a newer CLI, log in, backup → pull the
# digest → start it (migrations run at start) → health check → migration-head
# check → on failure: the previous images, the backup restored, the failure
# recorded (the administrators' banner and `statera doctor` show it).
# Migrations only go forward, so a rollback is always a restore.
#
# Without --to, the target is the newest release the last check-in listed
# (`statera update-schedule` prints it; versions there are bare x.y.z and are
# normalized to app-vx.y.z). Run from the host (`statera update`) or by the
# updater container in the scheduled window — the same path.
#
# STATERA_UPDATE_FORCE_FAIL=1 fails the health check on purpose: the
# rehearsal of the rollback (acceptance 5).
#
# Environment:
#   STATERA_APP_RELEASE_BASE_URL  where the App release manifest is served
#                                 (default: the App release's GitHub page)
set -eu

STATERA_CLI_VERSION=1.2.3
STATERA_REPOSITORY=Juxtalabs/statera-enterprise-deploy
DIR=${STATERA_DIR:-/opt/statera}
log() { echo "statera update: $*"; }

if [ ! -f "$DIR/lib.sh" ]; then
  echo "Error: $DIR/lib.sh is missing — run the pinned installer (install.sh) to update this bundle" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$DIR/lib.sh"

# docker-compose.proxy.yml exists when install.sh was given --proxy-network: it
# joins the App to an existing reverse proxy's Docker network.
compose() {
  if [ -f "$DIR/docker-compose.proxy.yml" ]; then
    docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" -f "$DIR/docker-compose.proxy.yml" "$@"
  else
    docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"
  fi
}
app() { compose exec -T app statera "$@"; }

[ -f "$DIR/.env" ] || statera_die "$DIR/.env does not exist: Statera is not installed"
current=""
if [ -f "$DIR/state/current-release" ]; then
  current=$(sed -n '1p' "$DIR/state/current-release")
fi
if [ -z "$current" ]; then
  current=$(sed -n 's/^STATERA_RELEASE=//p' "$DIR/.env")
fi
[ -n "$current" ] || statera_die "no release is recorded in $DIR: run the pinned installer again"

target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) target=$2; shift 2 ;;
    --scheduled) shift ;;
    *) echo "usage: statera update [--to app-vX.Y.Z]" >&2; exit 2 ;;
  esac
done
if [ -z "$target" ]; then
  target=$(app update-schedule | sed -n 's/.*"target":"\([^"]*\)".*/\1/p')
fi
if [ -z "$target" ]; then
  log "version $current is the newest offered; nothing to do"
  exit 0
fi
target=$(statera_normalize_app_release "$target")
if [ "$target" = "$current" ]; then
  log "version $current is the newest offered; nothing to do"
  exit 0
fi
if statera_version_is_older "$(statera_release_version "$target")" "$(statera_release_version "$current")"; then
  statera_die "downgrades are not supported (this server is on $current)"
fi
log "$current → $target"

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT HUP INT TERM
base=${STATERA_APP_RELEASE_BASE_URL:-https://github.com/$STATERA_REPOSITORY/releases/download/$target}
manifest=$(statera_fetch_manifest "$target" "$base" "$STATERA_CLI_VERSION" "$tmp")
target_image=$(statera_manifest_value "$manifest" app_image)
target_postgres=$(statera_manifest_value "$manifest" postgres_image)
target_head=$(statera_manifest_value "$manifest" migration_head)

# The private image needs the registry credential Control hands out.
credential=$(app registry-credential)
server=$(printf '%s\n' "$credential" | sed -n 1p)
username=$(printf '%s\n' "$credential" | sed -n 2p)
printf '%s\n' "$credential" | sed -n 3p | docker login "$server" -u "$username" --password-stdin >/dev/null

archive=$(app backup | tail -n 1)
[ -n "$archive" ] || statera_die "the backup did not report an archive"
log "backup taken: $archive"

mkdir -p "$DIR/state"
cp -p "$DIR/.env" "$DIR/state/previous.env"
printf '%s\n' "$current" >"$DIR/state/previous-release"
statera_set_env "$DIR/.env" STATERA_RELEASE "$target"
statera_set_env "$DIR/.env" STATERA_IMAGE "$target_image"
statera_set_env "$DIR/.env" STATERA_POSTGRES_IMAGE "$target_postgres"
if ! compose pull app postgres; then
  cp -p "$DIR/state/previous.env" "$DIR/.env"
  app update-report --error "the image $target could not be pulled; still on $current" || true
  statera_die "the image could not be pulled; nothing changed"
fi
# PostgreSQL is recreated only when its digest changed (a short restart).
compose up -d postgres app

healthy=0
if [ "${STATERA_UPDATE_FORCE_FAIL:-}" != 1 ]; then
  tries=0
  while [ $tries -lt 36 ]; do
    if app health >/dev/null 2>&1; then
      healthy=1
      break
    fi
    tries=$((tries + 1))
    sleep 5
  done
fi

actual=""
if [ "$healthy" = 1 ]; then
  actual=$(app db head 2>/dev/null | tr -d '\r\n ')
fi

if [ "$healthy" = 1 ] && [ "$actual" = "$target_head" ]; then
  printf '%s\n' "$target" >"$DIR/state/current-release"
  printf '%s\n' "$target_head" >"$DIR/state/current-migration"
  chmod 600 "$DIR/state/current-release" "$DIR/state/current-migration"
  statera_record_operation "$DIR/state" update "$target" succeeded "$archive"
  app update-report
  log "updated from $current to $target (database at $target_head)"
  exit 0
fi

if [ "$healthy" = 1 ]; then
  reason="the database is at '${actual:-unknown}' but $target declares the migration head $target_head"
else
  reason="version $target failed its health check"
fi
log "$reason; rolling back to $current"
cp -p "$DIR/state/previous.env" "$DIR/.env"
compose stop app
compose up -d postgres
compose run --rm --no-deps -T app statera restore "$archive" --yes
compose up -d app
tries=0
until app health >/dev/null 2>&1 || [ $tries -ge 36 ]; do
  tries=$((tries + 1))
  sleep 5
done
statera_record_operation "$DIR/state" update "$target" rolled-back "$archive"
app update-report --error "$reason; $current and the backup taken before the update were restored" || true
log "rolled back to $current"
exit 1