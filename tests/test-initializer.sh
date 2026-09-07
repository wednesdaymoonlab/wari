#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../install.sh
source "$CORE_DIR/install.sh"

assert_eq '0.2.0' "$WARI_VERSION" \
    'initializer version matches the tracked launcher release'

PIPE_HELP_OUTPUT="$(bash -s -- --help <"$CORE_DIR/install.sh")"
assert_contains "$PIPE_HELP_OUTPUT" 'Add the tracked Wari launcher and lock' \
    'pipe mode runs the project initializer entrypoint'

INIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-initializer-test.XXXXXX")"
INIT_TMP="$(CDPATH= cd -- "$INIT_TMP" && pwd -P)"
trap 'rm -rf -- "$INIT_TMP"' EXIT

if ! declare -F initializer_main >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'project initializer entrypoint exists'
    finish_tests
    exit $?
fi

if declare -F parse_wari_release >/dev/null 2>&1; then
    parse_wari_release "$TEST_DIR/fixtures/wari-release.json"
    assert_eq 'v0.2.0' "$WARI_RELEASE_TAG" 'initializer accepts the exact stable Wari release'
    assert_eq '1111111111111111111111111111111111111111111111111111111111111111' "$WARI_ASSET_SHA256" \
        'initializer reads the launcher release digest'
    assert_eq '2222222222222222222222222222222222222222222222222222222222222222' "$WARI_LOCK_ASSET_SHA256" \
        'initializer reads the lock release digest'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'Wari release metadata parser exists'
fi

fetch_tracked_files() {
    local staging="$1"
    cp "$CORE_DIR/wari" "$staging/wari"
    cp "$CORE_DIR/wari.lock" "$staging/wari.lock"
    chmod 755 "$staging/wari"
}

PROJECT="$INIT_TMP/project with spaces"
mkdir -p "$PROJECT"
printf '*.log\n' >"$PROJECT/.gitignore"
(
    cd "$PROJECT"
    initializer_main --yes
)
INITIALIZER_STATUS=$?
assert_eq '0' "$INITIALIZER_STATUS" 'initializer publishes tracked project files'
assert_eq '0' "$(test -x "$PROJECT/wari"; printf '%s' "$?")" \
    'initializer publishes an executable launcher'
assert_eq '0' "$(test -f "$PROJECT/wari.lock"; printf '%s' "$?")" \
    'initializer publishes the lock'
assert_eq '0' "$(test ! -e "$PROJECT/.wari"; printf '%s' "$?")" \
    'initializer never installs a local runtime'
assert_contains "$(<"$PROJECT/.gitignore")" '*.log' \
    'initializer preserves existing ignore rules'
assert_contains "$(<"$PROJECT/.gitignore")" '/.wari/' \
    'initializer adds the local runtime ignore rule'
assert_eq '1' "$(awk '$0 == "# Wari local runtime" { count++ } END { print count + 0 }' \
    "$PROJECT/.gitignore")" 'initializer writes one managed ignore block'

ensure_gitignore_block "$PROJECT"
assert_eq '1' "$(awk '$0 == "# Wari local runtime" { count++ } END { print count + 0 }' \
    "$PROJECT/.gitignore")" 'ignore management is idempotent'

COLLISION_PROJECT="$INIT_TMP/collision"
mkdir "$COLLISION_PROJECT"
printf 'user launcher' >"$COLLISION_PROJECT/wari"
assert_fails 'initializer refuses an existing launcher' \
    bash -c 'source "$1/install.sh"; fetch_tracked_files() { return 90; }; cd "$2"; initializer_main --yes' \
    _ "$CORE_DIR" "$COLLISION_PROJECT"
assert_eq 'user launcher' "$(<"$COLLISION_PROJECT/wari")" \
    'initializer preserves an existing launcher collision'

LEGACY_PROJECT="$INIT_TMP/legacy"
mkdir -p "$LEGACY_PROJECT/.wari"
cp "$TEST_DIR/fixtures/wari-0.1-dispatcher" "$LEGACY_PROJECT/.wari/wari"
chmod 755 "$LEGACY_PROJECT/.wari/wari"
ln "$LEGACY_PROJECT/.wari/wari" "$LEGACY_PROJECT/wari"
cat >"$LEGACY_PROJECT/.wari/manifest.json" <<'LEGACY_MANIFEST'
{
  "wari_version": "0.1.0",
  "checksum_verified": true
}
LEGACY_MANIFEST

set +e
(
    cd "$LEGACY_PROJECT"
    initializer_main --migrate --yes
)
MIGRATION_STATUS=$?
set -e
assert_eq '0' "$MIGRATION_STATUS" 'explicit migration converts a recognized legacy layout'
assert_eq '0' "$(test ! "$LEGACY_PROJECT/wari" -ef \
    "$LEGACY_PROJECT/.wari/wari"; printf '%s' "$?")" \
    'migration replaces the linked root dispatcher with the tracked launcher'
assert_eq "$(calculate_checksum sha256 "$TEST_DIR/fixtures/wari-0.1-dispatcher")" \
    "$(calculate_checksum sha256 "$LEGACY_PROJECT/.wari/wari")" \
    'migration leaves the legacy dispatcher untouched'
assert_eq '0' "$(test -f "$LEGACY_PROJECT/wari.lock"; printf '%s' "$?")" \
    'migration publishes the tracked lock'

AMBIGUOUS_PROJECT="$INIT_TMP/ambiguous"
mkdir -p "$AMBIGUOUS_PROJECT/.wari"
cp "$LEGACY_PROJECT/.wari/wari" "$AMBIGUOUS_PROJECT/.wari/wari"
cp "$LEGACY_PROJECT/.wari/manifest.json" "$AMBIGUOUS_PROJECT/.wari/manifest.json"
cp "$AMBIGUOUS_PROJECT/.wari/wari" "$AMBIGUOUS_PROJECT/wari"
assert_fails 'migration rejects a dispatcher that is not the legacy hard link' \
    bash -c 'source "$1/install.sh"; cd "$2"; initializer_main --migrate --yes' \
    _ "$CORE_DIR" "$AMBIGUOUS_PROJECT"

FORGED_PROJECT="$INIT_TMP/forged-legacy"
mkdir -p "$FORGED_PROJECT/.wari"
printf '%s\n' '#!/usr/bin/env bash' 'printf "unrelated executable\\n"' \
    >"$FORGED_PROJECT/.wari/wari"
chmod 755 "$FORGED_PROJECT/.wari/wari"
ln "$FORGED_PROJECT/.wari/wari" "$FORGED_PROJECT/wari"
cp "$LEGACY_PROJECT/.wari/manifest.json" "$FORGED_PROJECT/.wari/manifest.json"
assert_fails 'migration rejects a forged legacy manifest and dispatcher' \
    bash -c 'source "$1/install.sh"; cd "$2"; initializer_main --migrate --yes' \
    _ "$CORE_DIR" "$FORGED_PROJECT"
assert_contains "$(<"$FORGED_PROJECT/.wari/wari")" 'unrelated executable' \
    'failed migration preserves the unrelated executable'

finish_tests
