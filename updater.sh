#!/bin/sh
# The scheduled update (the bundle's `updater` container). Every five minutes
# it asks the App whether a run is due — an administrator asked for the update
# from the Lisensi & fitur screen, or a window is set, a newer release was
# listed by the last check-in, and this window has not been used yet — and if
# so runs the same update.sh as `statera update`. The window is off until an
# administrator sets one (the same screen, or `statera update --schedule
# "sun 02:00"`).
#
# The base image (docker:27-cli) carries the Docker CLI but no curl or jq,
# which update.sh needs to download and validate the release manifest; they
# are installed from Alpine's repository before the first run, retrying until
# the network is up.
set -u

DIR=${STATERA_DIR:-/opt/statera}
while ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; do
  echo "statera updater: installing curl and jq"
  if apk add --no-cache curl jq >/dev/null 2>&1; then
    break
  fi
  sleep 60
done
while :; do
  plan=$(docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" \
    exec -T app statera update-schedule 2>/dev/null || true)
  case "$plan" in
    *'"due":true'*)
      # A run that stopped before it could report (no manifest, no login)
      # would leave the screen's request open and be retried every round.
      sh "$DIR/update.sh" --scheduled         || docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml"           exec -T app statera update-report --only-open           --error "the update stopped before it started; see the updater's log (docker logs)"         || true ;;
  esac
  sleep 300
done