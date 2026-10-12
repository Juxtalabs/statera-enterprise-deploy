#!/usr/bin/env bash
# Shell tests for update.sh (JUX-103): every failure after the App was stopped
# ends in a recorded, truthful outcome — `rolled-back` only when the previous
# version is healthy on its previous migration head, `recovery-failed` with the
# App left stopped otherwise — and one lock covers update and restore. Run by
# .github/workflows/release-cli.yml in the public
# Juxtalabs/statera-enterprise-deploy repository; it also runs in the private
# statera-erp repository against deploy/onprem/bundle.
#
# A fake `docker` first on PATH logs every invocation and answers from control
# files, so update.sh is driven without Docker and without a real installation.
# The release manifest is served by a local HTTP server through
# STATERA_APP_RELEASE_BASE_URL, as test-statera.sh does.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
if [[ -f "$repository_root/lib.sh" ]]; then
  bundle="$repository_root"
else
  bundle="$repository_root/../bundle"
fi
for required in lib.sh update.sh; do
  [[ -f "$bundle/$required" ]] || { printf 'FAIL: missing %s\n' "$bundle/$required" >&2; exit 1; }
done

for tool in flock jq curl sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'SKIP: needs %s\n' "$tool"
    exit 0
  fi
done
python_command=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -c 'import http.server' >/dev/null 2>&1; then
    python_command="$candidate"
    break
  fi
done
if [[ -z "$python_command" ]]; then
  printf 'SKIP: needs python (the local release server)\n'
  exit 0
fi

temporary="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -r "$temporary"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- the fake docker ----------------------------------------------------------

fake_dir="$temporary/bin"
fake_log="$temporary/docker.log"
fake_control="$temporary/control"
mkdir -p "$fake_dir" "$fake_control"
export STATERA_FAKE_LOG="$fake_log"
export STATERA_FAKE_CONTROL_DIR="$fake_control"
cat >"$fake_dir/docker" <<'STUB'
#!/bin/sh
# A fake docker: log the invocation, then answer from the control files.
# `<name>` holds an exit code (default 0); `<name>.sleep` a delay in seconds.
echo "docker $*" >>"$STATERA_FAKE_LOG"
rolled_back=0
grep -q "statera restore" "$STATERA_FAKE_LOG" && rolled_back=1
started=0
grep -q "up -d postgres app" "$STATERA_FAKE_LOG" && started=1
name=default
case "$*" in
  login*) cat >/dev/null ;;
  pull*) name=pull ;;
  *"statera registry-credential"*) printf 'ghcr.io\nstatera\nsecret\n' ;;
  *"statera update-report"*) name=report ;;
  *"statera backup"*)
    name=backup
    echo "/var/lib/statera/backups/statera-backup-20261012T000000Z.sbk"
    ;;
  *"statera restore"*) name=restore ;;
  *"statera db head"*)
    if [ "$rolled_back" = 1 ]; then name=head_previous
    elif [ "$started" = 1 ]; then name=head_target
    else name=head_before
    fi
    cat "$STATERA_FAKE_CONTROL_DIR/$name.value" 2>/dev/null || true
    exit 0
    ;;
  *"statera health"*)
    if [ "$rolled_back" = 1 ]; then name=health_previous; else name=health_target; fi
    ;;
  *"up -d postgres app"*) name=up_target ;;
  *"up -d postgres"*) name=up_postgres ;;
  *"up -d app"*) name=up_app ;;
esac
if [ -f "$STATERA_FAKE_CONTROL_DIR/$name.sleep" ]; then
  sleep "$(cat "$STATERA_FAKE_CONTROL_DIR/$name.sleep")"
fi
code=0
if [ -f "$STATERA_FAKE_CONTROL_DIR/$name" ]; then
  code="$(cat "$STATERA_FAKE_CONTROL_DIR/$name")"
fi
exit "$code"
STUB
chmod +x "$fake_dir/docker"
export PATH="$fake_dir:$PATH"

# --- the release ----------------------------------------------------------------

target_head="4300_target"
previous_head="4200_previous"
mkdir -p "$temporary/www"
cat >"$temporary/www/app-v9.9.9.json" <<EOF
{
  "schema_version": 1,
  "release": "app-v9.9.9",
  "source_commit": "0000000000000000000000000000000000000000",
  "app_image": "ghcr.io/juxtalabs/statera-app@sha256:1111111111111111111111111111111111111111111111111111111111111111",
  "postgres_image": "ghcr.io/juxtalabs/statera-postgres@sha256:2222222222222222222222222222222222222222222222222222222222222222",
  "migration_head": "$target_head",
  "minimum_cli": "1.0.0",
  "created_at": "2026-10-12T00:00:00Z"
}
EOF
printf '%s  app-v9.9.9.json\n' "$(sha256sum "$temporary/www/app-v9.9.9.json" | cut -d' ' -f1)" \
  >"$temporary/www/app-v9.9.9.sha256"
"$python_command" -m http.server 18735 --bind 127.0.0.1 --directory "$temporary/www" >/dev/null 2>&1 &
server_pid=$!
ready=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:18735/app-v9.9.9.json" -o /dev/null 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
[[ "$ready" == 1 ]] || fail "the local HTTP server did not start"
export STATERA_APP_RELEASE_BASE_URL="http://127.0.0.1:18735"
export STATERA_UPDATE_POLL_SECONDS=0

# --- helpers --------------------------------------------------------------------

install="$temporary/install"
# A fresh fake install on app-v1.0.0, a healthy target and a healthy previous.
new_install() {
  rm -rf "$install"
  mkdir -p "$install/state"
  cp "$bundle/lib.sh" "$bundle/update.sh" "$install/"
  : >"$install/docker-compose.yml"
  printf 'STATERA_RELEASE=app-v1.0.0\nSTATERA_IMAGE=old-app\nSTATERA_POSTGRES_IMAGE=old-postgres\n' >"$install/.env"
  printf 'app-v1.0.0\n' >"$install/state/current-release"
  cp "$install/.env" "$temporary/env.before"
  : >"$fake_log"
  rm -f "$fake_control"/*
  printf '%s\n' "$previous_head" >"$fake_control/head_before.value"
  printf '%s\n' "$target_head" >"$fake_control/head_target.value"
  printf '%s\n' "$previous_head" >"$fake_control/head_previous.value"
}
control() {
  printf '%s\n' "$2" >"$fake_control/$1"
}
run_update() {
  status=0
  STATERA_DIR="$install" sh "$install/update.sh" --to app-v9.9.9 >"$temporary/out" 2>&1 || status=$?
}
result() {
  jq -r .result "$install/state/last-operation.json" 2>/dev/null || true
}
log_has() {
  grep -Fq -- "$1" "$fake_log"
}
log_lacks() {
  ! log_has "$1"
}
line_of() {
  grep -Fn -- "$1" "$fake_log" | head -n 1 | cut -d: -f1
}
env_is_previous() {
  cmp -s "$install/.env" "$temporary/env.before"
}

# --- D-T1: success ---------------------------------------------------------------

new_install
run_update
[[ "$status" -eq 0 ]] || fail "D-T1: a healthy update exited $status: $(cat "$temporary/out")"
[[ "$(result)" == "succeeded" ]] || fail "D-T1: recorded $(result)"
pulled="$(line_of "pull ghcr.io/juxtalabs/statera-app")"
stopped="$(line_of "stop app")"
backed="$(line_of "statera backup")"
upped="$(line_of "up -d postgres app")"
[[ -n "$pulled" && -n "$stopped" && -n "$backed" && -n "$upped" ]] || fail "D-T1: a step is missing"
[[ "$pulled" -lt "$stopped" && "$stopped" -lt "$backed" && "$backed" -lt "$upped" ]] \
  || fail "D-T1: the order is not pull, stop, backup, start"
[[ ! -e "$install/state/update-in-progress" ]] || fail "D-T1: the in-progress marker was left"
grep -q '^STATERA_RELEASE=app-v9.9.9$' "$install/.env" || fail "D-T1: .env does not name the target"

# --- D-T2: the pull fails → nothing changed -----------------------------------------

new_install
control pull 1
run_update
[[ "$status" -ne 0 ]] || fail "D-T2: a failed pull was accepted"
env_is_previous || fail "D-T2: .env changed although the pull failed"
log_lacks "stop app" || fail "D-T2: the App was stopped although the pull failed"

# --- D-T3: the target cannot be started → rolled back -------------------------------

new_install
control up_target 1
run_update
[[ "$status" -eq 1 ]] || fail "D-T3: exited $status"
[[ "$(result)" == "rolled-back" ]] || fail "D-T3: recorded $(result)"
env_is_previous || fail "D-T3: .env is not the previous one"
log_has "statera restore" || fail "D-T3: the backup was not restored"

# --- D-T4: the target never becomes healthy → rolled back ---------------------------

new_install
control health_target 1
run_update
[[ "$status" -eq 1 ]] || fail "D-T4: exited $status"
[[ "$(result)" == "rolled-back" ]] || fail "D-T4: recorded $(result)"
env_is_previous || fail "D-T4: .env is not the previous one"

# --- D-T5: the migration head differs from the manifest → rolled back ---------------

new_install
printf 'something_else\n' >"$fake_control/head_target.value"
run_update
[[ "$status" -eq 1 ]] || fail "D-T5: exited $status"
[[ "$(result)" == "rolled-back" ]] || fail "D-T5: recorded $(result)"

# --- D-T6: the rollback's restore fails → recovery-failed, App stopped --------------

new_install
control health_target 1
control restore 1
run_update
[[ "$status" -eq 2 ]] || fail "D-T6: exited $status"
[[ "$(result)" == "recovery-failed" ]] || fail "D-T6: recorded $(result)"
[[ -e "$install/state/update-in-progress" ]] || fail "D-T6: the in-progress marker is gone"
last_app="$(grep -E '(up -d app|stop app)' "$fake_log" | tail -n 1)"
[[ "$last_app" == *"stop app"* ]] || fail "D-T6: the App was not left stopped: $last_app"

# --- D-T7: restored, but the previous version never becomes healthy -----------------

new_install
control health_target 1
control health_previous 1
run_update
[[ "$status" -eq 2 ]] || fail "D-T7: exited $status"
[[ "$(result)" == "recovery-failed" ]] || fail "D-T7: recorded $(result)"

# --- D-T8: restored, but the database is not at its previous head -------------------

new_install
control health_target 1
printf 'something_else\n' >"$fake_control/head_previous.value"
run_update
[[ "$status" -eq 2 ]] || fail "D-T8: exited $status"
[[ "$(result)" == "recovery-failed" ]] || fail "D-T8: recorded $(result)"

# --- D-T9: two updates at once → exactly one runs -----------------------------------

new_install
printf '3\n' >"$fake_control/pull.sleep"
STATERA_DIR="$install" sh "$install/update.sh" --to app-v9.9.9 >"$temporary/first.out" 2>&1 &
first=$!
sleep 1
status=0
STATERA_DIR="$install" sh "$install/update.sh" --to app-v9.9.9 >"$temporary/second.out" 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "D-T9: a second update ran beside the first"
grep -q "another Statera operation" "$temporary/second.out" \
  || fail "D-T9: the second update was not refused for the lock: $(cat "$temporary/second.out")"
wait "$first" || fail "D-T9: the first update failed: $(cat "$temporary/first.out")"
[[ "$(grep -c 'statera backup' "$fake_log")" -eq 1 ]] || fail "D-T9: more than one backup was taken"

# --- D-T10: an update beside a held lock (a restore holds the same file) ------------

new_install
flock -x "$install/.statera.lock" -c 'sleep 5' &
holder=$!
sleep 1
run_update
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$status" -ne 0 ]] || fail "D-T10: an update ran while the lock was held"
[[ ! -s "$fake_log" ]] || fail "D-T10: docker was called although the lock was held"

# --- D-T11: an unfinished update is not built on ------------------------------------

new_install
printf 'app-v1.0.0\napp-v9.9.8\n/var/lib/statera/backups/old.sbk\n' >"$install/state/update-in-progress"
run_update
[[ "$status" -ne 0 ]] || fail "D-T11: an update ran over an unfinished one"
grep -q "old.sbk" "$temporary/out" || fail "D-T11: the refusal does not name the backup"
[[ ! -s "$fake_log" ]] || fail "D-T11: docker was called over an unfinished update"

# --- D-T12: interrupted during the health check → rolled back -----------------------

new_install
control health_target 1
printf '1\n' >"$fake_control/health_target.sleep"
STATERA_DIR="$install" sh "$install/update.sh" --to app-v9.9.9 >"$temporary/out" 2>&1 &
running=$!
for _ in $(seq 1 100); do
  log_has "statera health" && break
  sleep 0.2
done
log_has "statera health" || fail "D-T12: the health check never started"
kill -TERM "$running"
wait "$running" 2>/dev/null || true
[[ "$(result)" == "rolled-back" ]] || fail "D-T12: recorded $(result): $(cat "$temporary/out")"
env_is_previous || fail "D-T12: .env is not the previous one"

printf 'update tests passed.\n'
