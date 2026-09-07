#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"

LAUNCHER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-launcher-test.XXXXXX")"
LAUNCHER_TMP="$(CDPATH= cd -- "$LAUNCHER_TMP" && pwd -P)"
trap 'rm -rf -- "$LAUNCHER_TMP"' EXIT

PROJECT="$LAUNCHER_TMP/project with spaces"
FAKE_BIN="$LAUNCHER_TMP/fake-bin"
NETWORK_MARKER="$LAUNCHER_TMP/network-called"
mkdir -p "$PROJECT" "$FAKE_BIN"
cp "$CORE_DIR/wari" "$PROJECT/wari"
cp "$CORE_DIR/wari.lock" "$PROJECT/wari.lock"
chmod 755 "$PROJECT/wari"

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
: >"$WARI_NETWORK_MARKER"
exit 99
FAKE_CURL
chmod 755 "$FAKE_BIN/curl"

HELP_OUTPUT="$(cd "$PROJECT" && PATH="$FAKE_BIN:$PATH" \
    WARI_NETWORK_MARKER="$NETWORK_MARKER" ./wari help)"
assert_contains "$HELP_OUTPUT" 'setup' 'help lists setup before a runtime exists'
assert_contains "$HELP_OUTPUT" 'composer' 'help lists runtime commands before setup'

VERSION_OUTPUT="$(cd "$PROJECT" && ./wari --version)"
assert_contains "$VERSION_OUTPUT" 'Wari 0.2.0' 'version works before setup'

for command_name in php composer serve frankenphp create-project; do
    set +e
    COMMAND_OUTPUT="$(cd "$PROJECT" && PATH="$FAKE_BIN:$PATH" \
        WARI_NETWORK_MARKER="$NETWORK_MARKER" ./wari "$command_name" --version 2>&1)"
    COMMAND_STATUS=$?
    set -e
    assert_eq '1' "$COMMAND_STATUS" "$command_name requires explicit setup"
    assert_contains "$COMMAND_OUTPUT" './wari setup' \
        "$command_name explains how to install the runtime"
done

assert_eq '0' "$(test ! -e "$NETWORK_MARKER"; printf '%s' "$?")" \
    'runtime commands never download implicitly'
assert_eq '0' "$(test ! -e "$PROJECT/.wari"; printf '%s' "$?")" \
    'runtime commands never create local state implicitly'

set +e
UNKNOWN_OUTPUT="$(cd "$PROJECT" && ./wari unknown 2>&1)"
UNKNOWN_STATUS=$?
set -e
assert_eq '1' "$UNKNOWN_STATUS" 'unknown command fails before runtime validation'
assert_contains "$UNKNOWN_OUTPUT" 'unknown Wari command' \
    'unknown command identifies the invalid input'

FOREIGN_PROJECT="$LAUNCHER_TMP/foreign"
mkdir -p "$FOREIGN_PROJECT/.wari"
cp "$CORE_DIR/wari" "$FOREIGN_PROJECT/wari"
cp "$CORE_DIR/wari.lock" "$FOREIGN_PROJECT/wari.lock"
printf 'keep me' >"$FOREIGN_PROJECT/.wari/user-data"
set +e
FOREIGN_OUTPUT="$(cd "$FOREIGN_PROJECT" && ./wari php --version 2>&1)"
FOREIGN_STATUS=$?
set -e
assert_eq '1' "$FOREIGN_STATUS" 'rejects an unrecognized runtime directory'
assert_contains "$FOREIGN_OUTPUT" 'not recognized' \
    'distinguishes an unrecognized runtime from a missing runtime'
assert_eq 'keep me' "$(<"$FOREIGN_PROJECT/.wari/user-data")" \
    'does not mutate an unrecognized runtime'

write_runtime_fixture() {
    local project="$1"
    local lock_sha="$2"
    local os="$3"
    local arch="$4"
    local linux_build_json='null'

    if [[ "$os" == 'linux' ]]; then
        linux_build_json='"static"'
    fi

    mkdir -p "$project/.wari/runtime"
    printf '%s\n' 'Wari runtime layout 2' >"$project/.wari/.wari-owned"
    cp "$CORE_DIR/wari" "$project/wari"
    cp "$CORE_DIR/wari.lock" "$project/wari.lock"
    for command_name in php composer create-project serve frankenphp; do
        cat >"$project/.wari/$command_name" <<'FAKE_RUNTIME'
#!/usr/bin/env bash
case "$(basename -- "$0")/${1-}" in
    php/--version) printf 'PHP 8.4.0 (cli)\n' ;;
    composer/--version) printf 'Composer version 2.8.11 2025-01-01\n' ;;
    frankenphp/version) printf 'FrankenPHP v1.12.7\n' ;;
    *) printf 'runtime-cwd=%s\n' "$PWD"; exit "${FAKE_RUNTIME_EXIT:-0}" ;;
esac
FAKE_RUNTIME
        chmod 755 "$project/.wari/$command_name"
    done
    cp "$project/.wari/frankenphp" "$project/.wari/runtime/frankenphp"
    printf 'fake composer' >"$project/.wari/runtime/composer.phar"
    cat >"$project/.wari/manifest.json" <<EOF
{
  "layout_version": 2,
  "lock_sha256": "$lock_sha",
  "wari_version": "0.2.0",
  "frankenphp_version": "1.12.7",
  "php_version": "8.4.0",
  "composer_version": "2.8.11",
  "os": "$os",
  "architecture": "$arch",
  "linux_build": $linux_build_json,
  "checksum_verified": true,
  "slsa_verified": false
}
EOF
}

if command -v sha256sum >/dev/null 2>&1; then
    LOCK_SHA="$(sha256sum "$CORE_DIR/wari.lock")"
else
    LOCK_SHA="$(shasum -a 256 "$CORE_DIR/wari.lock")"
fi
LOCK_SHA="${LOCK_SHA%%[[:space:]]*}"

STALE_PROJECT="$LAUNCHER_TMP/stale"
write_runtime_fixture "$STALE_PROJECT" "$(printf '%064d' 9)" linux x86_64
set +e
STALE_OUTPUT="$(cd "$STALE_PROJECT" && ./wari composer --version 2>&1)"
STALE_STATUS=$?
set -e
assert_eq '1' "$STALE_STATUS" 'rejects a runtime created from another lock'
assert_contains "$STALE_OUTPUT" 'does not match wari.lock' \
    'identifies a stale runtime lock'

READY_PROJECT="$LAUNCHER_TMP/ready"
case "$(uname -s)" in
    Linux) TEST_OS='linux' ;;
    Darwin) TEST_OS='darwin' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) TEST_ARCH='x86_64' ;;
    arm64|aarch64) TEST_ARCH='arm64' ;;
esac
write_runtime_fixture "$READY_PROJECT" "$LOCK_SHA" "$TEST_OS" "$TEST_ARCH"
set +e
READY_OUTPUT="$(cd "$READY_PROJECT/nothing" 2>/dev/null || cd "$READY_PROJECT"; \
    FAKE_RUNTIME_EXIT=17 ./wari php script.php 2>&1)"
READY_STATUS=$?
set -e
assert_eq '17' "$READY_STATUS" 'ready runtime forwards delegated exit status'
assert_contains "$READY_OUTPUT" "runtime-cwd=$READY_PROJECT" \
    'ready runtime dispatches from the physical project root'

MISMATCH_PROJECT="$LAUNCHER_TMP/mismatched-pair"
mkdir "$MISMATCH_PROJECT"
cp "$CORE_DIR/wari" "$MISMATCH_PROJECT/wari"
cp "$CORE_DIR/wari.lock" "$MISMATCH_PROJECT/wari.lock"
printf '# interrupted update\n' >>"$MISMATCH_PROJECT/wari"
set +e
MISMATCH_OUTPUT="$(cd "$MISMATCH_PROJECT" && ./wari help 2>&1)"
MISMATCH_STATUS=$?
set -e
assert_eq '1' "$MISMATCH_STATUS" 'launcher rejects a mismatched tracked pair'
assert_contains "$MISMATCH_OUTPUT" 'does not match wari.lock' \
    'tracked-pair mismatch gives a recovery diagnosis'

finish_tests
