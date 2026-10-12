#!/bin/sh
# statera update [--to app-vX.Y.Z]  (Phase 31 WP6/WP8; enhancement E6)
#
# The App release is pinned by manifest: download app-vX.Y.Z.json + .sha256
# from the release's assets, verify the checksum and the shape (release.schema
# .json), refuse a release that needs a newer CLI, log in, pull the digest →
# stop the App → backup → start the new one (migrations run at start) →
# health check → migration-head check → on failure: the previous images, the
# backup restored, and the outcome recorded as it really went — `rolled-back`
# once the previous version is healthy on its previous head, `recovery-failed`
# with the App left stopped otherwise (the administrators' banner and
# `statera doctor` show it). Migrations only go forward, so a rollback is
# always a restore. One lock (`.statera.lock`) covers update and restore.
#
# Without --to, the target is the newest release the last check-in listed
# (`statera update-schedule` prints it; versions there are bare x.y.z and are
# normalized to app-vx.y.z). Run from the host (`statera update`) or by the
# updater container — in the scheduled window, or when an administrator asked
# for the update from the Lisensi & fitur screen — the same path. Every run is
# recorded in the App's update history (`statera update-report`).
#
# STATERA_UPDATE_FORCE_FAIL=1 fails the health check on purpose: the
# rehearsal of the rollback (acceptance 5).
#
# Environment:
#   STATERA_APP_RELEASE_BASE_URL  where the App release manifest is served
#                                 (default: the App release's GitHub page)
set -eu

STATERA_CLI_VERSION=1.3.4
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
trigger=cli
while [ $# -gt 0 ]; do
  case "$1" in
    --to) target=$2; shift 2 ;;
    --scheduled) trigger=schedule; shift ;;
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

# One mutating operation at a time: a manual run, the updater and both
# restores take the same lock.
statera_lock "$DIR"
if [ -f "$DIR/state/update-in-progress" ]; then
  statera_die "an earlier update did not finish and its rollback failed or was cut short. The backup taken before it is $(sed -n 3p "$DIR/state/update-in-progress"). Run: statera restore <that archive>, then remove $DIR/state/update-in-progress"
fi

# The outcome, for the update history. An App older than 1.3.2 does not know
# the history's arguments: the plain form still records the failure there.
report() {
  app update-report --trigger "$trigger" --from "$current" --to "$target" "$@"     || app update-report "$@"
}

tmp=$(mktemp -d)
poll=${STATERA_UPDATE_POLL_SECONDS:-5}
# idle: nothing changed. stopped: the App is down, .env untouched.
# switched: .env names the target. finished: an outcome was recorded.
phase=idle
reason=""
archive=""
previous_head=""

# Back to the previous release, and say truthfully how that went: rolled-back
# only when the old version is healthy on its previous migration head;
# otherwise recovery-failed, with the App left stopped.
rollback() {
  log "$reason; rolling back to $current"
  cp -p "$DIR/state/previous.env" "$DIR/.env"
  compose stop app || true
  recovery=""
  compose up -d postgres || recovery="PostgreSQL could not be started on the previous image"
  if [ -z "$recovery" ]; then
    compose run --rm --no-deps -T app statera restore "$archive" --yes \
      || recovery="the backup $archive could not be restored"
  fi
  if [ -z "$recovery" ]; then
    compose up -d app || recovery="version $current could not be started"
  fi
  if [ -z "$recovery" ]; then
    tries=0
    until app health >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ $tries -ge 36 ]; then
        recovery="version $current failed its health check after the restore"
        break
      fi
      sleep "$poll"
    done
  fi
  if [ -z "$recovery" ] && [ -n "$previous_head" ]; then
    head_now=$(app db head 2>/dev/null | tr -d '\r\n ' || true)
    [ "$head_now" = "$previous_head" ] \
      || recovery="the database is at '${head_now:-unknown}' after the restore, not at $previous_head"
  fi
  phase=finished
  if [ -z "$recovery" ]; then
    rm -f "$DIR/state/update-in-progress"
    statera_record_operation "$DIR/state" update "$target" rolled-back "$archive"
    report --error "$reason; $current and the backup taken before the update were restored" || true
    log "rolled back to $current"
    exit 1
  fi
  compose stop app || true
  statera_record_operation "$DIR/state" update "$target" recovery-failed "$archive"
  report --error "$reason; the rollback also failed: $recovery" || true
  echo "Error: $reason. The rollback also failed: $recovery. The App was left stopped. The backup taken before the update is $archive. Fix the cause, then run: statera restore $archive" >&2
  exit 2
}

# However the script ends, the installation is not left half-switched.
# shellcheck disable=SC2329
finish() {
  status=$?
  trap - EXIT
  rm -rf "$tmp"
  case "$phase" in
    stopped) compose up -d app || true ;;
    switched) reason="the update was interrupted"; rollback ;;
  esac
  exit "$status"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM
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

# Pulled before anything changes, so a failed pull leaves the install as it is.
if ! docker pull "$target_image" >/dev/null || ! docker pull "$target_postgres" >/dev/null; then
  report --error "the image $target could not be pulled; still on $current" || true
  statera_die "the image could not be pulled; nothing changed"
fi

# The App is stopped from before the backup until the verdict, so no write
# lands between the backup and a rollback that restores it.
mkdir -p "$DIR/state"
previous_head=$(app db head 2>/dev/null | tr -d '\r\n ' || true)
phase=stopped
compose stop app
archive=$(compose run --rm --no-deps -T app statera backup | tail -n 1)
case "$archive" in
  *.sbk) ;;
  *) statera_die "the backup did not report an archive" ;;
esac
log "backup taken: $archive"

cp -p "$DIR/.env" "$DIR/state/previous.env"
printf '%s\n' "$current" >"$DIR/state/previous-release"
phase=switched
printf '%s\n%s\n%s\n' "$current" "$target" "$archive" >"$DIR/state/update-in-progress"
statera_set_env "$DIR/.env" STATERA_RELEASE "$target"
statera_set_env "$DIR/.env" STATERA_IMAGE "$target_image"
statera_set_env "$DIR/.env" STATERA_POSTGRES_IMAGE "$target_postgres"
# PostgreSQL is recreated only when its digest changed (a short restart).
started=1
compose up -d postgres app || started=0

healthy=0
if [ "$started" = 1 ] && [ "${STATERA_UPDATE_FORCE_FAIL:-}" != 1 ]; then
  tries=0
  while [ $tries -lt 36 ]; do
    if app health >/dev/null 2>&1; then
      healthy=1
      break
    fi
    tries=$((tries + 1))
    sleep "$poll"
  done
fi

actual=""
if [ "$healthy" = 1 ]; then
  actual=$(app db head 2>/dev/null | tr -d '\r\n ' || true)
fi

if [ "$healthy" = 1 ] && [ "$actual" = "$target_head" ]; then
  printf '%s\n' "$target" >"$DIR/state/current-release"
  printf '%s\n' "$target_head" >"$DIR/state/current-migration"
  chmod 600 "$DIR/state/current-release" "$DIR/state/current-migration"
  rm -f "$DIR/state/update-in-progress"
  statera_record_operation "$DIR/state" update "$target" succeeded "$archive"
  phase=finished
  report || true
  log "updated from $current to $target (database at $target_head)"
  exit 0
fi

if [ "$started" = 0 ]; then
  reason="version $target could not be started"
elif [ "$healthy" = 1 ]; then
  reason="the database is at '${actual:-unknown}' but $target declares the migration head $target_head"
else
  reason="version $target failed its health check"
fi
rollback
