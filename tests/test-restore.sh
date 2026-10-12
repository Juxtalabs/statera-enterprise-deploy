#!/usr/bin/env bash
# Shell tests for the host half of JUX-104 (enhancement E3): `bundle/statera`'s
# local and offsite restore paths never start the App after a failed restore,
# never empty the PostgreSQL data directory before the current one is copied
# aside, and refuse to run beside another mutating operation. Run by
# .github/workflows/release-cli.yml in the public
# Juxtalabs/statera-enterprise-deploy repository; it also runs in the private
# statera-erp repository against deploy/onprem/bundle.
#
# A fake `docker` first on PATH logs every invocation and answers with the
# exit code a control file names, so the wrapper is driven without Docker and
# without a real installation. The offsite branch refuses to run as a
# non-root user; C-T7…C-T10 report `SKIP: needs root` there.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
if [[ -f "$repository_root/lib.sh" ]]; then
  bundle="$repository_root"
else
  bundle="$repository_root/../bundle"
fi
for required in lib.sh statera; do
  [[ -f "$bundle/$required" ]] || { printf 'FAIL: missing %s\n' "$bundle/$required" >&2; exit 1; }
done

# The lock is what makes C-T11 meaningful; without it there is nothing to test.
if ! command -v flock >/dev/null 2>&1; then
  printf 'SKIP: needs flock\n'
  exit 0
fi

temporary="$(mktemp -d)"
cleanup() {
  rm -r "$temporary"
}
trap cleanup EXIT HUP INT TERM

fake_dir="$temporary/bin"
mkdir -p "$fake_dir"
cat >"$fake_dir/docker" <<'STUB'
#!/bin/sh
# A fake docker: log the invocation, then exit with the code the matching
# control file names (`default` when none matches).
echo "docker $*" >>"$STATERA_FAKE_LOG"
name="default"
handled=""
for argument in "$@"; do
  if [ "$argument" = "pgbackrest" ]; then
    handled=1
    case "$*" in
      *"--stanza=statera info"*) name=pgbackrest ;;
      *"--stanza=statera"*) name=pgbackrest_restore ;;
      *) name=pgbackrest ;;
    esac
  fi
done
if [ -z "$handled" ]; then
  case "$*" in
    *"cp -a /var/lib/postgresql/data"*) name=copyaside ;;
    *"statera offsite-backup restore"*) name=attachments ;;
    *"statera restore"*) name=restore ;;
  esac
fi
code=0
if [ -f "$STATERA_FAKE_CONTROL_DIR/$name" ]; then
  code="$(cat "$STATERA_FAKE_CONTROL_DIR/$name")"
fi
exit "$code"
STUB
chmod +x "$fake_dir/docker"
export PATH="$fake_dir:$PATH"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

fake_log="$temporary/docker.log"
fake_control="$temporary/control"
export STATERA_FAKE_LOG="$fake_log"
export STATERA_FAKE_CONTROL_DIR="$fake_control"
mkdir -p "$fake_control"
: >"$fake_log"

# A fresh fake install folder; each scenario edits the control files only.
new_install() {
  rm -rf "$temporary/install"
  mkdir -p "$temporary/install/state"
  cp "$bundle/lib.sh" "$temporary/install/lib.sh"
  cp "$bundle/statera" "$temporary/install/statera"
  : >"$temporary/install/docker-compose.yml"
  : >"$fake_log"
  rm -f "$fake_control"/*
}
control() {
  printf '%s\n' "$2" >"$fake_control/$1"
}
log_has() {
  grep -Fq -- "$1" "$fake_log"
}
log_lacks() {
  ! log_has "$1"
}

# --- C-T5: a failed local restore leaves the App stopped ----------------------

new_install
control restore 1
status=0
STATERA_DIR="$temporary/install" "$temporary/install/statera" restore archive.sbk >/dev/null 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "a failed restore was reported as success"
log_has "restore archive.sbk" || fail "the restore command was not run"
log_has "stop app" || fail "the App was not stopped before the restore"
log_lacks "up -d app" || fail "the App was started after a failed restore"

# --- C-T6: a successful local restore starts the App --------------------------

new_install
status=0
STATERA_DIR="$temporary/install" "$temporary/install/statera" restore archive.sbk >/dev/null 2>&1 || status=$?
[[ "$status" -eq 0 ]] || fail "a successful restore exited $status"
log_has "restore archive.sbk" || fail "the restore command was not run"
log_has "up -d app" || fail "the App was not started after a successful restore"

# --- C-T7..C-T10: the offsite restore ----------------------------------------

if [[ "$(id -u)" != "0" ]]; then
  printf 'SKIP: needs root (C-T7..C-T10)\n'
else
  identity="$temporary/identity.txt"
  printf 'AGE-SECRET-KEY-TEST\n' >"$identity"

  # C-T7: the pgBackRest preflight fails → nothing is stopped, nothing deleted.
  new_install
  control pgbackrest 1
  status=0
  STATERA_DIR="$temporary/install" "$temporary/install/statera" offsite-backup restore \
    --identity "$identity" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail "an unreadable repository was accepted"
  log_lacks "stop app" || fail "the App was stopped although the preflight failed"
  log_lacks "find /var/lib/postgresql/data -mindepth 1 -delete" \
    || fail "the data directory was emptied although the preflight failed"

  # C-T8: the copy-aside fails → the data directory is never emptied.
  new_install
  control copyaside 1
  status=0
  STATERA_DIR="$temporary/install" "$temporary/install/statera" offsite-backup restore \
    --identity "$identity" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail "a failed copy-aside was accepted"
  log_has "cp -a /var/lib/postgresql/data" || fail "the database was not copied aside"
  log_lacks "find /var/lib/postgresql/data -mindepth 1 -delete" \
    || fail "the data directory was emptied although the copy failed"

  # C-T9: pgBackRest fails → the copy is put back and the App stays stopped.
  new_install
  control pgbackrest_restore 1
  status=0
  STATERA_DIR="$temporary/install" "$temporary/install/statera" offsite-backup restore \
    --identity "$identity" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail "a failed database restore was accepted"
  log_has "cp -a /previous/." || fail "the previous database was not put back"
  log_lacks "up -d app" || fail "the App was started after a failed database restore"

  # C-T10: the attachment step fails → the App stays stopped.
  new_install
  control attachments 1
  status=0
  STATERA_DIR="$temporary/install" "$temporary/install/statera" offsite-backup restore \
    --identity "$identity" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail "a failed attachment restore was accepted"
  log_lacks "up -d app" || fail "the App was started after a failed attachment restore"
fi

# --- C-T11: a second restore cannot run beside a held lock --------------------

new_install
flock -x "$temporary/install/.statera.lock" -c 'sleep 10' &
holder=$!
sleep 1
status=0
STATERA_DIR="$temporary/install" "$temporary/install/statera" restore archive.sbk >/dev/null 2>&1 || status=$?
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$status" -ne 0 ]] || fail "a second restore was accepted while the lock was held"
[[ ! -s "$fake_log" ]] || fail "docker was called although the lock was held"

printf 'restore tests passed.\n'