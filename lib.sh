#!/bin/sh
# Shared helpers for the Statera install bundle (Phase 31 WP8; enhancement
# E6): `install.sh`, `update.sh` and the release tests all source this file.
# It is never run directly and sets no global state: every function takes its
# paths as arguments, so the tests can drive each one alone.
#
# POSIX sh only (the server's /bin/sh may be dash), and no `sort -V` (the
# scheduled update runs inside a busybox container).

# Print `Error: <text>` on stderr and stop — the bundle's one refusal shape.
statera_die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# A valid install instance name (enhancement: several installs on one server):
# 1–20 characters, the first a lowercase letter or digit, the rest letters,
# digits or dashes. The name becomes a folder, a compose project and a command.
statera_valid_instance() {
  case "$1" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 20 ]
}

# Download one asset. https only, except an explicit http base — which exists
# solely so a local HTTP server can rehearse a release end to end through
# STATERA_RELEASE_BASE_URL / STATERA_APP_RELEASE_BASE_URL.
statera_download() {
  case "$1" in
    https://*) curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2" ;;
    http://*) curl --proto '=http' -fsSL "$1" -o "$2" ;;
    *) return 1 ;;
  esac
}

# The SHA-256 of one file.
statera_sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

# The expected digest from a one-line `sha256sum` file (`<hash>  <name>`), or
# nothing when the file does not carry one.
statera_expected_sha256() {
  awk 'NR == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$1"
}

# Verify `file` against `expected`; `what` names it in the refusal.
statera_verify_sha256() {
  if [ -z "$2" ]; then
    statera_die "no checksum was found for $3"
  fi
  if [ "$(statera_sha256_of "$1")" != "$2" ]; then
    statera_die "checksum mismatch for $3"
  fi
}

# Verify `file` against its line in a SHA256SUMS file.
statera_verify_against_sums() {
  statera_verify_sha256 "$1" \
    "$(awk -v asset="$2" '$2 == asset || $2 == "*" asset {print $1; exit}' "$3")" "$2"
}

# App release names: `1.1.0` and `app-v1.1.0` both mean `app-v1.1.0`.
statera_normalize_app_release() {
  case "$1" in
    app-v*) printf '%s\n' "$1" ;;
    *) printf 'app-v%s\n' "$1" ;;
  esac
}

# The version part of an app release: `app-v1.1.0` -> `1.1.0`.
statera_release_version() {
  printf '%s\n' "${1#app-v}"
}

# Whether `current` is an older x.y.z than `required` (equal is not older).
# Field by field and numeric, so the busybox container needs nothing extra.
statera_version_is_older() {
  [ "$1" = "$2" ] && return 1
  _statera_current=$1
  _statera_required=$2
  _statera_cm=${_statera_current%%.*}
  _statera_current=${_statera_current#*.}
  _statera_cmi=${_statera_current%%.*}
  _statera_cp=${_statera_current#*.}
  _statera_rm=${_statera_required%%.*}
  _statera_required=${_statera_required#*.}
  _statera_rmi=${_statera_required%%.*}
  _statera_rp=${_statera_required#*.}
  [ "$_statera_cm" -lt "$_statera_rm" ] && return 0
  [ "$_statera_cm" -gt "$_statera_rm" ] && return 1
  [ "$_statera_cmi" -lt "$_statera_rmi" ] && return 0
  [ "$_statera_cmi" -gt "$_statera_rmi" ] && return 1
  [ "$_statera_cp" -lt "$_statera_rp" ]
}

# One field of a release manifest.
statera_manifest_value() {
  jq -r ".$2" "$1"
}

# `statera_validate_manifest <release> <file> <cli-version>`: the shape of
# release.schema.json — a full 40-hex source commit, the App and PostgreSQL
# images pinned by GHCR digest, a migration head, `minimum_cli` — plus the
# CLI floor.
statera_validate_manifest() {
  if ! jq -e --arg release "$1" '
      (.release | test("^app-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and .release == $release
      and .schema_version == 1
      and (.source_commit | test("^[0-9a-f]{40}$"))
      and (.app_image | test("^ghcr\\.io/juxtalabs/statera-app@sha256:[0-9a-f]{64}$"))
      and (.postgres_image | test("^ghcr\\.io/juxtalabs/statera-postgres@sha256:[0-9a-f]{64}$"))
      and (.migration_head | type == "string" and length > 0)
      and (.minimum_cli | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.created_at | type == "string" and length > 0)
      and ((keys | sort) == (["app_image", "created_at", "migration_head", "minimum_cli", "postgres_image", "release", "schema_version", "source_commit"] | sort))' \
      "$2" >/dev/null; then
    statera_die "the manifest for $1 is not valid"
  fi
  _statera_minimum=$(statera_manifest_value "$2" minimum_cli)
  if statera_version_is_older "$3" "$_statera_minimum"; then
    statera_die "release $1 needs Statera CLI $_statera_minimum or newer (this server has $3): run statera self-update v$_statera_minimum"
  fi
}

# Download `<release>.json` + `<release>.sha256` from the release's asset base
# into `dir`, verify the checksum, validate the shape; echo the manifest path.
statera_fetch_manifest() {
  statera_download "$2/$1.json" "$4/$1.json" \
    || statera_die "release $1 was not found at $2"
  statera_download "$2/$1.sha256" "$4/$1.sha256" \
    || statera_die "the checksum for $1 was not found at $2"
  statera_verify_sha256 "$4/$1.json" "$(statera_expected_sha256 "$4/$1.sha256")" "$1.json"
  statera_validate_manifest "$1" "$4/$1.json" "$3"
  printf '%s\n' "$4/$1.json"
}

# Set (or append) one `key=value` in an env file.
statera_set_env() {
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >>"$1"
  fi
}

# Record the outcome of an install or update run — `state/last-operation.json`,
# which `statera`'s status and doctor read.
statera_record_operation() {
  jq -n \
    --arg operation "$2" \
    --arg release "$3" \
    --arg result "$4" \
    --arg backup "${5:-}" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{operation: $operation, release: $release, result: $result, backup: $backup, timestamp: $timestamp}' \
    >"$1/last-operation.json"
  chmod 600 "$1/last-operation.json"
}