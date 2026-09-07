#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"

UPDATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-update-test.XXXXXX")"
UPDATE_TMP="$(CDPATH= cd -- "$UPDATE_TMP" && pwd -P)"
trap 'rm -rf -- "$UPDATE_TMP"' EXIT

if ! declare -F update_main >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'tracked-file update command exists'
    finish_tests
    exit $?
fi

if declare -F parse_wari_release >/dev/null 2>&1; then
    parse_wari_release "$TEST_DIR/fixtures/wari-release.json"
    assert_eq 'v0.2.0' "$WARI_RELEASE_TAG" 'updater accepts stable release metadata'
    assert_eq '1111111111111111111111111111111111111111111111111111111111111111' \
        "$WARI_ASSET_SHA256" 'updater reads the launcher asset digest'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'updater release metadata parser exists'
fi

make_pair() {
    local directory="$1"
    local version="$2"
    mkdir -p "$directory"
    sed "s/^WARI_VERSION='[^']*'/WARI_VERSION='$version'/" \
        "$CORE_DIR/wari" >"$directory/wari"
    chmod 755 "$directory/wari"
    local launcher_sha
    launcher_sha="$(calculate_checksum sha256 "$directory/wari")"
    sed -e "s/^wari_version=.*/wari_version=$version/" \
        -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
        "$CORE_DIR/wari.lock" >"$directory/wari.lock"
}

PROJECT="$UPDATE_TMP/project"
CANDIDATE="$UPDATE_TMP/candidate"
make_pair "$PROJECT" '0.2.0'
make_pair "$CANDIDATE" '0.3.0'
mkdir "$PROJECT/.wari"
printf 'local runtime' >"$PROJECT/.wari/marker"

fetch_wari_update() {
    cp "$CANDIDATE/wari" "$1/wari"
    cp "$CANDIDATE/wari.lock" "$1/wari.lock"
    chmod 755 "$1/wari"
}

UPDATE_OUTPUT="$(WARI_PROJECT_ROOT="$PROJECT" WARI_LAUNCHER="$PROJECT/wari" \
    update_main --yes)"
UPDATE_STATUS=$?
assert_eq '0' "$UPDATE_STATUS" 'update replaces the tracked launcher and lock'
assert_contains "$UPDATE_OUTPUT" '0.2.0' 'update displays the current Wari version'
assert_contains "$UPDATE_OUTPUT" '0.3.0' 'update displays the proposed Wari version'
assert_contains "$UPDATE_OUTPUT" './wari setup' 'update keeps runtime replacement explicit'
assert_eq 'Wari 0.3.0' "$("$PROJECT/wari" --version)" \
    'update publishes the candidate launcher'
assert_contains "$(<"$PROJECT/wari.lock")" 'wari_version=0.3.0' \
    'update publishes the matching candidate lock'
assert_eq 'local runtime' "$(<"$PROJECT/.wari/marker")" \
    'update does not mutate the local runtime'

DECLINE_PROJECT="$UPDATE_TMP/decline"
make_pair "$DECLINE_PROJECT" '0.2.0'
set +e
(
    WARI_PROJECT_ROOT="$DECLINE_PROJECT"
    WARI_LAUNCHER="$DECLINE_PROJECT/wari"
    confirm_setup() { return 1; }
    update_main
) >/dev/null 2>&1
DECLINE_STATUS=$?
set -e
assert_eq '0' "$DECLINE_STATUS" 'declining update is a successful no-op'
assert_contains "$(<"$DECLINE_PROJECT/wari.lock")" 'wari_version=0.2.0' \
    'declining update preserves the tracked pair'

MODIFIED_PROJECT="$UPDATE_TMP/modified"
make_pair "$MODIFIED_PROJECT" '0.2.0'
printf '# local edit\n' >>"$MODIFIED_PROJECT/wari"
assert_fails 'update refuses a locally modified launcher' \
    env WARI_PROJECT_ROOT="$MODIFIED_PROJECT" \
    WARI_LAUNCHER="$MODIFIED_PROJECT/wari" bash -c \
    'source "$1/wari"; update_main --yes' _ "$MODIFIED_PROJECT"

finish_tests
