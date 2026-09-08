#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../install.sh
source "$CORE_DIR/install.sh"

assert_eq '0.3.0' "$WARI_VERSION" \
    'initializer version matches the tracked launcher release'

PIPE_HELP_OUTPUT="$(bash -s -- --help <"$CORE_DIR/install.sh")"
assert_contains "$PIPE_HELP_OUTPUT" 'Add the tracked Wari launcher and lock' \
    'pipe mode runs the project initializer entrypoint'
assert_contains "$PIPE_HELP_OUTPUT" '--local-source DIRECTORY' \
    'initializer documents local source mode'
assert_contains "$PIPE_HELP_OUTPUT" '--frankenphp VERSION' \
    'initializer documents exact dependency overrides'
assert_fails 'initializer rejects a launcher redirect to an unrelated host' \
    validate_initializer_effective_url \
    'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
    'https://example.test/wari'
assert_eq '0' "$(validate_initializer_effective_url \
    'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
    'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
    >/dev/null 2>&1; printf '%s' "$?")" \
    'initializer accepts launcher downloads on the exact raw GitHub URL'
assert_fails 'initializer rejects --wari without a value' initializer_main --wari
assert_fails 'initializer rejects --local-source without a value' \
    initializer_main --local-source
assert_fails 'initializer rejects tag and local-source together' \
    initializer_main --wari 0.2.1 --local-source .

INIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-initializer-test.XXXXXX")"
INIT_TMP="$(CDPATH= cd -- "$INIT_TMP" && pwd -P)"
trap 'rm -rf -- "$INIT_TMP"' EXIT

if ! declare -F initializer_main >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'project initializer entrypoint exists'
    finish_tests
    exit $?
fi

if declare -F fetch_tagged_launcher >/dev/null 2>&1; then
    TAG_STAGING="$INIT_TMP/tag-staging"
    mkdir "$TAG_STAGING"
    download_file() {
        INITIALIZER_DOWNLOADED_URL="$1"
        cp "$CORE_DIR/wari" "$2"
    }
    fetch_tagged_launcher "$TAG_STAGING" '0.3.0'
    assert_eq \
        'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
        "$INITIALIZER_DOWNLOADED_URL" \
        'initializer downloads the launcher from the exact Wari tag'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'exact-tag launcher fetch exists'
fi

VERSION_MISMATCH_STAGING="$INIT_TMP/version-mismatch-staging"
mkdir "$VERSION_MISMATCH_STAGING"
set +e
(
    fetch_tagged_launcher() {
        sed "s/^WARI_VERSION='[^']*'/WARI_VERSION='0.3.0'/" \
            "$CORE_DIR/wari" >"$1/wari"
        chmod 755 "$1/wari"
    }
    generate_staged_lock() { return 88; }
    fetch_tracked_files "$VERSION_MISMATCH_STAGING" '0.2.1' '' '' '' static
) >/dev/null 2>&1
VERSION_MISMATCH_STATUS=$?
set -e
assert_eq '0' "$(test "$VERSION_MISMATCH_STATUS" -ne 0; printf '%s' "$?")" \
    'initializer rejects a launcher whose version differs from its tag'

GENERATION_FAILURE_PROJECT="$INIT_TMP/generation-failure-project"
mkdir "$GENERATION_FAILURE_PROJECT"
set +e
(
    cd "$GENERATION_FAILURE_PROJECT"
    fetch_tracked_files() { return 89; }
    initializer_main --yes
) >/dev/null 2>&1
GENERATION_FAILURE_STATUS=$?
set -e
assert_eq '0' "$(test "$GENERATION_FAILURE_STATUS" -ne 0; printf '%s' "$?")" \
    'initializer reports lock generation failure'
assert_eq '0' "$(test ! -e "$GENERATION_FAILURE_PROJECT/wari" && \
    test ! -e "$GENERATION_FAILURE_PROJECT/wari.lock"; printf '%s' "$?")" \
    'failed lock generation publishes no tracked files'

LOCAL_FAKE_BIN="$INIT_TMP/local-fake-bin"
LOCAL_PROJECT="$INIT_TMP/local-source-project"
mkdir -p "$LOCAL_FAKE_BIN" "$LOCAL_PROJECT"
cat >"$LOCAL_FAKE_BIN/curl" <<'LOCAL_FAKE_CURL'
#!/usr/bin/env bash
set -u
destination=''
url=''
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output|-o) destination="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    https://api.github.com/repos/php/frankenphp/releases/tags/v1.12.7)
        cp "$WARI_TEST_FIXTURES/frankenphp-release.json" "$destination" ;;
    https://getcomposer.org/download/2.8.11/composer.phar.sha256sum)
        printf '%064d  composer.phar\n' 7 >"$destination" ;;
    https://composer.github.io/installer.sig)
        printf '%096d\n' 8 >"$destination" ;;
    *) exit 22 ;;
esac
printf '%s' "$url"
LOCAL_FAKE_CURL
chmod 755 "$LOCAL_FAKE_BIN/curl"
set +e
PATH="$LOCAL_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    bash -c 'source "$1/install.sh"; cd "$2"; initializer_main --yes \
        --local-source "$1" --frankenphp 1.12.7 --composer 2.8.11' \
        _ "$CORE_DIR" "$LOCAL_PROJECT"
LOCAL_STATUS=$?
set -e
assert_eq '0' "$LOCAL_STATUS" \
    'local-source initialization generates and publishes a launcher lock pair'
assert_eq '0' "$(test ! -e "$LOCAL_PROJECT/.wari"; printf '%s' "$?")" \
    'local-source initialization leaves runtime setup explicit'
if [[ "$LOCAL_STATUS" -eq 0 ]]; then
    assert_eq 'Wari 0.3.0' "$("$LOCAL_PROJECT/wari" --version)" \
        'local-source initialization publishes the working launcher'
    bash "$LOCAL_PROJECT/wari" --validate-pair "$LOCAL_PROJECT/wari.lock"
    assert_eq '0' "$?" 'local-source initialization publishes a valid pair'
fi

fetch_tracked_files() {
    local staging="$1"
    local launcher_sha
    cp "$CORE_DIR/wari" "$staging/wari"
    launcher_sha="$(calculate_checksum sha256 "$staging/wari")"
    sed "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
        "$CORE_DIR/wari.lock" >"$staging/wari.lock"
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

SIGNAL_PROJECT="$INIT_TMP/signal-project"
mkdir "$SIGNAL_PROJECT"
set +e
(
    cd "$SIGNAL_PROJECT"
    mv() {
        local source destination
        if [[ "${1-}" == -- ]]; then shift; fi
        source="$1"; destination="$2"
        command mv "$source" "$destination" || return $?
        if [[ "$destination" == "$SIGNAL_PROJECT/wari" ]]; then
            sh -c 'kill -TERM "$PPID"'
        fi
    }
    initializer_main --yes
) >/dev/null 2>&1
SIGNAL_STATUS=$?
set -e
assert_eq '0' "$SIGNAL_STATUS" \
    'initializer masks TERM across launcher publication bookkeeping'
if [[ "$SIGNAL_STATUS" -eq 0 ]]; then
    bash "$SIGNAL_PROJECT/wari" --validate-pair "$SIGNAL_PROJECT/wari.lock"
    assert_eq '0' "$?" 'signal-safe initializer publishes a valid pair'
fi

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
