#!/usr/bin/env bash
# Shell tests for the release helpers in lib.sh (enhancement E6): version
# comparison, checksum verification, and release-manifest validation. Run by
# .github/workflows/release-cli.yml in the public Juxtalabs/statera-enterprise-deploy
# repository; it also runs in the private statera-erp repository against
# deploy/onprem/bundle/lib.sh.
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$repository_root/lib.sh" ]]; then
  bundle="$repository_root"
else
  bundle="$repository_root/../bundle"
fi

for required in lib.sh install.sh update.sh statera; do
  [[ -f "$bundle/$required" ]] || { printf 'FAIL: missing %s\n' "$bundle/$required" >&2; exit 1; }
done
# shellcheck source=/dev/null
. "$bundle/lib.sh"

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

# A function that refuses (calls statera_die -> exit 1) must be run in a
# subshell, or it would end the test run itself.
expect_refusal() {
  local description="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail "$description was accepted"
  fi
}

# --- release names and version comparison -----------------------------------

[[ "$(statera_normalize_app_release 1.1.0)" == "app-v1.1.0" ]] || fail "1.1.0 did not normalize"
[[ "$(statera_normalize_app_release app-v1.1.0)" == "app-v1.1.0" ]] || fail "app-v1.1.0 was changed"
[[ "$(statera_release_version app-v1.1.0)" == "1.1.0" ]] || fail "the release version was not extracted"

statera_version_is_older 1.0.0 1.0.1 || fail "1.0.0 < 1.0.1"
statera_version_is_older 1.0.0 2.0.0 || fail "1.0.0 < 2.0.0"
statera_version_is_older 1.9.0 1.10.0 || fail "1.9.0 < 1.10.0 (numeric, not lexical)"
if statera_version_is_older 1.0.1 1.0.0; then fail "1.0.1 is not older than 1.0.0"; fi
if statera_version_is_older 1.1.0 1.1.0; then fail "equal versions are not older"; fi
if statera_version_is_older 1.10.0 1.9.0; then fail "1.10.0 is not older than 1.9.0"; fi

# The release workflow validates the tag against these constants; the three
# scripts must agree with each other even before CI exists.
installer_version="$(sed -n 's/^STATERA_CLI_VERSION=//p' "$bundle/install.sh" | head -n 1)"
updater_version="$(sed -n 's/^STATERA_CLI_VERSION=//p' "$bundle/update.sh" | head -n 1)"
command_version="$(sed -n 's/^STATERA_CLI_VERSION=//p' "$bundle/statera" | head -n 1)"
[[ -n "$installer_version" ]] || fail "install.sh has no STATERA_CLI_VERSION"
[[ "$installer_version" == "$updater_version" ]] || fail "install.sh and update.sh disagree on the CLI version"
[[ "$installer_version" == "$command_version" ]] || fail "install.sh and statera disagree on the CLI version"

# --- checksums ---------------------------------------------------------------

printf 'payload\n' >"$temporary/asset"
digest="$(statera_sha256_of "$temporary/asset")"
statera_verify_sha256 "$temporary/asset" "$digest" asset
printf '%s  asset\n' "$digest" >"$temporary/SHA256SUMS"
statera_verify_against_sums "$temporary/asset" asset "$temporary/SHA256SUMS"
expect_refusal "a wrong checksum" \
  statera_verify_sha256 "$temporary/asset" "0000000000000000000000000000000000000000000000000000000000000000" asset
expect_refusal "an asset missing from SHA256SUMS" \
  statera_verify_against_sums "$temporary/asset" other "$temporary/SHA256SUMS"
expect_refusal "a missing checksum" statera_verify_sha256 "$temporary/asset" "" asset
[[ "$(statera_expected_sha256 "$temporary/SHA256SUMS")" == "$digest" ]] || fail "the digest was not read back"
printf 'not a checksum\n' >"$temporary/garbage.sha256"
[[ -z "$(statera_expected_sha256 "$temporary/garbage.sha256")" ]] || fail "a garbage checksum file was accepted"

# --- the release manifest ----------------------------------------------------

cat >"$temporary/app-v1.1.0.json" <<'EOF'
{
  "schema_version": 1,
  "release": "app-v1.1.0",
  "source_commit": "0000000000000000000000000000000000000000",
  "app_image": "ghcr.io/juxtalabs/statera-app@sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "postgres_image": "ghcr.io/juxtalabs/statera-postgres@sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "migration_head": "4200_recurring_journals",
  "minimum_cli": "1.0.0",
  "created_at": "2026-10-08T00:00:00Z"
}
EOF
statera_validate_manifest app-v1.1.0 "$temporary/app-v1.1.0.json" 1.1.0
[[ "$(statera_manifest_value "$temporary/app-v1.1.0.json" migration_head)" == "4200_recurring_journals" ]] \
  || fail "migration_head was not read back"

# A tag-pinned image (no digest) must be refused.
jq '.app_image = "ghcr.io/juxtalabs/statera-app:1.1.0"' \
  "$temporary/app-v1.1.0.json" >"$temporary/tag-pinned.json"
expect_refusal "a tag-pinned image" \
  statera_validate_manifest app-v1.1.0 "$temporary/tag-pinned.json" 1.1.0

# A tag-pinned PostgreSQL image must be refused too.
jq '.postgres_image = "ghcr.io/juxtalabs/statera-postgres:1.2.0"' \
  "$temporary/app-v1.1.0.json" >"$temporary/tag-pinned-postgres.json"
expect_refusal "a tag-pinned PostgreSQL image" \
  statera_validate_manifest app-v1.1.0 "$temporary/tag-pinned-postgres.json" 1.1.0

# Another repository's image must be refused.
jq '.app_image = "ghcr.io/juxtalabs/statera-other@sha256:1111111111111111111111111111111111111111111111111111111111111111"' \
  "$temporary/app-v1.1.0.json" >"$temporary/wrong-image.json"
expect_refusal "a different image repository" \
  statera_validate_manifest app-v1.1.0 "$temporary/wrong-image.json" 1.1.0

# An extra field (schema drift) must be refused.
jq '. + {web_image: "ghcr.io/juxtalabs/statera-web@sha256:1111111111111111111111111111111111111111111111111111111111111111"}' \
  "$temporary/app-v1.1.0.json" >"$temporary/extra-field.json"
expect_refusal "an unknown manifest field" \
  statera_validate_manifest app-v1.1.0 "$temporary/extra-field.json" 1.1.0

# A missing migration head must be refused.
jq 'del(.migration_head)' "$temporary/app-v1.1.0.json" >"$temporary/no-head.json"
expect_refusal "a manifest without migration_head" \
  statera_validate_manifest app-v1.1.0 "$temporary/no-head.json" 1.1.0

# The manifest's release name must be the one asked for.
expect_refusal "a manifest for another release" \
  statera_validate_manifest app-v1.0.0 "$temporary/app-v1.1.0.json" 1.1.0

# A release that needs a newer CLI must be refused; one the CLI satisfies must pass.
jq '.minimum_cli = "1.2.0"' "$temporary/app-v1.1.0.json" >"$temporary/needs-newer.json"
expect_refusal "a release that needs a newer CLI" \
  statera_validate_manifest app-v1.1.0 "$temporary/needs-newer.json" 1.1.0
jq '.minimum_cli = "1.1.0"' "$temporary/app-v1.1.0.json" >"$temporary/needs-same.json"
statera_validate_manifest app-v1.1.0 "$temporary/needs-same.json" 1.1.0

# --- fetch: checksum failure and the happy path over a local HTTP server -----

python_command=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -c 'import http.server' >/dev/null 2>&1; then
    python_command="$candidate"
    break
  fi
done
if [[ -n "$python_command" ]]; then
  mkdir -p "$temporary/www" "$temporary/fetched"
  cp "$temporary/app-v1.1.0.json" "$temporary/www/app-v1.1.0.json"
  printf '%s  app-v1.1.0.json\n' "$(statera_sha256_of "$temporary/www/app-v1.1.0.json")" \
    >"$temporary/www/app-v1.1.0.sha256"
  "$python_command" -m http.server 18734 --bind 127.0.0.1 --directory "$temporary/www" >/dev/null 2>&1 &
  server_pid=$!
  ready=0
  for _ in $(seq 1 50); do
    if statera_download "http://127.0.0.1:18734/app-v1.1.0.json" "$temporary/probe.json" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.2
  done
  [[ "$ready" == 1 ]] || fail "the local HTTP server did not start"
  fetched="$(statera_fetch_manifest app-v1.1.0 "http://127.0.0.1:18734" 1.1.0 "$temporary/fetched")"
  [[ "$fetched" == "$temporary/fetched/app-v1.1.0.json" ]] || fail "fetch returned $fetched"
  printf '0000000000000000000000000000000000000000000000000000000000000000  app-v1.1.0.json\n' \
    >"$temporary/www/app-v1.1.0.sha256"
  expect_refusal "a download whose checksum does not match" \
    statera_fetch_manifest app-v1.1.0 "http://127.0.0.1:18734" 1.1.0 "$temporary/fetched"
  expect_refusal "a manifest that is not published" \
    statera_fetch_manifest app-v9.9.9 "http://127.0.0.1:18734" 1.1.0 "$temporary/fetched"
  kill "$server_pid" 2>/dev/null || true
  server_pid=""
else
  printf 'note: python is not installed; the local HTTP fetch test was skipped.\n'
fi

printf 'CLI tests passed.\n'