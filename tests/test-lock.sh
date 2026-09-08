#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"

if [[ ! -f "$CORE_DIR/wari" ]]; then
    fail 'tracked wari launcher exists'
    TESTS_RUN=$((TESTS_RUN + 1))
    finish_tests
    exit $?
fi

# shellcheck source=../wari
source "$CORE_DIR/wari"

LOCK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-lock-test.XXXXXX")"
trap 'rm -rf -- "$LOCK_TMP"' EXIT

sha256_digit() {
    printf '%064d' "$1"
}

sha384_digit() {
    printf '%096d' "$1"
}

write_valid_lock() {
    local path="$1"

    {
        printf '%s\n' \
            'lock_version=1' \
            'wari_version=0.2.1' \
            'frankenphp_version=1.12.7' \
            'composer_version=2.8.11' \
            'linux_build=static'
        printf 'wari_sha256=%s\n' "$(sha256_digit 0)"
        printf 'composer_installer_sha384=%s\n' "$(sha384_digit 0)"
        printf 'composer_sha256=%s\n' "$(sha256_digit 1)"
        printf 'frankenphp_linux_x86_64_sha256=%s\n' "$(sha256_digit 2)"
        printf 'frankenphp_linux_arm64_sha256=%s\n' "$(sha256_digit 3)"
        printf 'frankenphp_macos_x86_64_sha256=%s\n' "$(sha256_digit 4)"
        printf 'frankenphp_macos_arm64_sha256=%s\n' "$(sha256_digit 5)"
    } >"$path"
}

VALID_LOCK="$LOCK_TMP/valid.lock"
write_valid_lock "$VALID_LOCK"

parse_lock "$VALID_LOCK"
assert_eq '0' "$?" 'accepts a complete canonical lock'
assert_eq '0.2.1' "$LOCK_WARI_VERSION" 'loads the locked Wari version'
assert_eq '1.12.7' "$LOCK_FRANKENPHP_VERSION" 'loads the locked FrankenPHP version'
assert_eq '2.8.11' "$LOCK_COMPOSER_VERSION" 'loads the locked Composer version'
assert_eq 'static' "$LOCK_LINUX_BUILD" 'loads the locked Linux build'

DUPLICATE_LOCK="$LOCK_TMP/duplicate.lock"
cp "$VALID_LOCK" "$DUPLICATE_LOCK"
printf '%s\n' 'wari_version=0.2.1' >>"$DUPLICATE_LOCK"
assert_fails 'rejects a duplicate lock key' parse_lock "$DUPLICATE_LOCK"

UNKNOWN_LOCK="$LOCK_TMP/unknown.lock"
cp "$VALID_LOCK" "$UNKNOWN_LOCK"
printf '%s\n' 'download_url=https://example.test/binary' >>"$UNKNOWN_LOCK"
assert_fails 'rejects an unknown lock key' parse_lock "$UNKNOWN_LOCK"

MISSING_LOCK="$LOCK_TMP/missing.lock"
sed '/^composer_version=/d' "$VALID_LOCK" >"$MISSING_LOCK"
assert_fails 'rejects a missing required lock key' parse_lock "$MISSING_LOCK"

UPPERCASE_HASH_LOCK="$LOCK_TMP/uppercase-hash.lock"
sed 's/^wari_sha256=.*/wari_sha256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' \
    "$VALID_LOCK" >"$UPPERCASE_HASH_LOCK"
assert_fails 'rejects a non-canonical uppercase checksum' parse_lock "$UPPERCASE_HASH_LOCK"

MALICIOUS_SENTINEL="$LOCK_TMP/executed"
MALICIOUS_LOCK="$LOCK_TMP/malicious.lock"
sed "s|^wari_version=.*|wari_version=\$(touch $MALICIOUS_SENTINEL)|" \
    "$VALID_LOCK" >"$MALICIOUS_LOCK"
assert_fails 'rejects shell syntax in a lock value' parse_lock "$MALICIOUS_LOCK"
assert_eq '0' "$(test ! -e "$MALICIOUS_SENTINEL"; printf '%s' "$?")" \
    'never executes lock-file values'

GNU_LOCK="$LOCK_TMP/gnu.lock"
sed 's/^linux_build=static$/linux_build=gnu/' "$VALID_LOCK" >"$GNU_LOCK"
parse_lock "$GNU_LOCK"
PLATFORM_OS='linux'
PLATFORM_ARCH='x86_64'
select_locked_asset
assert_eq 'frankenphp-linux-x86_64-gnu' "$ASSET_NAME" \
    'selects the locked GNU Linux x86 asset'
assert_eq "$(sha256_digit 2)" "$ASSET_SHA256" \
    'selects the locked Linux x86 checksum'

parse_lock "$VALID_LOCK"
PLATFORM_OS='darwin'
PLATFORM_ARCH='arm64'
select_locked_asset
assert_eq 'frankenphp-mac-arm64' "$ASSET_NAME" \
    'selects the macOS Apple Silicon asset'
assert_eq "$(sha256_digit 5)" "$ASSET_SHA256" \
    'selects the locked macOS ARM checksum'

assert_fails 'semantic versions reject prerelease text' \
    validate_semver '1.2.3-rc1'
assert_fails 'download policy rejects a redirect to an unrelated host' \
    validate_effective_download_url \
    'https://getcomposer.org/versions' 'https://example.test/versions'
assert_eq '0' "$(validate_effective_download_url \
    'https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-mac-arm64' \
    'https://release-assets.githubusercontent.com/github-production-release-asset/file' \
    >/dev/null 2>&1; printf '%s' "$?")" \
    'download policy accepts the official GitHub release asset CDN'

if declare -F parse_frankenphp_release >/dev/null 2>&1; then
    parse_frankenphp_release \
        "$TEST_DIR/fixtures/frankenphp-release.json" '1.12.7' static
    assert_eq '1.12.7' "$RESOLVED_FRANKENPHP_VERSION" \
        'FrankenPHP metadata resolves the requested stable version'
    assert_eq '1111111111111111111111111111111111111111111111111111111111111111' \
        "$RESOLVED_FRANKENPHP_LINUX_X86_64_SHA256" \
        'FrankenPHP metadata selects the static Linux x86 checksum'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'FrankenPHP release parser exists'
fi

if declare -F parse_composer_latest >/dev/null 2>&1; then
    parse_composer_latest "$TEST_DIR/fixtures/composer-versions.json"
    assert_eq '2.10.3' "$RESOLVED_COMPOSER_VERSION" \
        'Composer metadata selects the first current stable version'
    cat >"$LOCK_TMP/composer-split-object.json" <<'COMPOSER_SPLIT_OBJECT'
{
  "stable": [
    {
      "path": "/download/2.10.3/composer.phar"
    },
    {
      "version": "2.10.3"
    }
  ]
}
COMPOSER_SPLIT_OBJECT
    assert_fails 'Composer metadata cannot combine fields from different releases' \
        parse_composer_latest "$LOCK_TMP/composer-split-object.json"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'Composer latest metadata parser exists'
fi

OUTPUT_TARGET="$LOCK_TMP/output-target"
printf 'keep me\n' >"$OUTPUT_TARGET"
ln -s "$OUTPUT_TARGET" "$LOCK_TMP/output-link"
assert_fails 'lock generation rejects an output symlink' \
    generate_lock_main "$LOCK_TMP/output-link"
assert_eq 'keep me' "$(<"$OUTPUT_TARGET")" \
    'rejected generator output leaves the symlink target unchanged'

CANON_FAKE_BIN="$LOCK_TMP/canonical-fake-bin"
CANONICAL_LOCK="$LOCK_TMP/canonical.lock"
mkdir -p "$CANON_FAKE_BIN"
cat >"$CANON_FAKE_BIN/curl" <<'CANONICAL_FAKE_CURL'
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
    https://api.github.com/repos/php/frankenphp/releases/latest|\
    https://api.github.com/repos/php/frankenphp/releases/tags/v1.12.7)
        cp "$WARI_TEST_FIXTURES/frankenphp-release.json" "$destination"
        ;;
    https://getcomposer.org/versions)
        cp "$WARI_TEST_FIXTURES/composer-versions.json" "$destination"
        ;;
    https://getcomposer.org/download/2.8.11/composer.phar.sha256sum)
        printf '%s  composer.phar\n' \
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
            >"$destination"
        ;;
    https://getcomposer.org/download/2.10.3/composer.phar.sha256sum)
        printf '%s\n' \
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
            >"$destination"
        ;;
    https://composer.github.io/installer.sig)
        printf '%s\n' \
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
            >"$destination"
        ;;
    *) exit 22 ;;
esac
printf '%s' "$url"
CANONICAL_FAKE_CURL
chmod 755 "$CANON_FAKE_BIN/curl"

set +e
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    bash "$CORE_DIR/wari" --generate-lock "$CANONICAL_LOCK" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static
CANONICAL_STATUS=$?
set -e
assert_eq '0' "$CANONICAL_STATUS" \
    'hidden generator creates a lock from exact official metadata'
if [[ "$CANONICAL_STATUS" -eq 0 ]]; then
    parse_lock "$CANONICAL_LOCK"
    assert_eq '1.12.7' "$LOCK_FRANKENPHP_VERSION" \
        'generated lock records exact FrankenPHP version'
    assert_eq '2.8.11' "$LOCK_COMPOSER_VERSION" \
        'generated lock records exact Composer version'
    assert_eq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        "$LOCK_COMPOSER_SHA256" \
        'generated lock records official Composer checksum metadata'
    assert_eq "$(calculate_checksum sha256 "$CORE_DIR/wari")" \
        "$LOCK_WARI_SHA256" \
        'generated lock binds the executing launcher bytes'
fi

ENV_LOCK="$LOCK_TMP/environment-isolated.lock"
set +e
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    WARI_LAUNCHER="$CORE_DIR/install.sh" \
    bash "$CORE_DIR/wari" --generate-lock "$ENV_LOCK" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static >/dev/null 2>&1
ENV_LOCK_STATUS=$?
set -e
assert_eq '0' "$ENV_LOCK_STATUS" \
    'hidden generator ignores an externally supplied launcher path'
if [[ "$ENV_LOCK_STATUS" -eq 0 ]]; then
    parse_lock "$ENV_LOCK"
    assert_eq "$(calculate_checksum sha256 "$CORE_DIR/wari")" \
        "$LOCK_WARI_SHA256" \
        'environment isolation binds the script that is actually executing'
fi

GENERATOR="$CORE_DIR/tools/generate-lock.sh"
if [[ -f "$GENERATOR" ]]; then
    GENERATOR_HELP="$(bash "$GENERATOR" --help)"
    assert_contains "$GENERATOR_HELP" \
        'generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>' \
        'lock generator documents its exact inputs'
    assert_fails 'lock generator rejects an incomplete version' \
        bash "$GENERATOR" 0.2 1.12.7 2.8.11 static
    assert_fails 'lock generator rejects an invalid Linux build' \
        bash "$GENERATOR" 0.2.1 1.12.7 2.8.11 dynamic

    DELEGATE_ROOT="$LOCK_TMP/delegate-root"
    DELEGATE_MARKER="$LOCK_TMP/delegate-arguments"
    mkdir -p "$DELEGATE_ROOT/tools"
    cp "$GENERATOR" "$DELEGATE_ROOT/tools/generate-lock.sh"
    cat >"$DELEGATE_ROOT/wari" <<'FAKE_WARI'
#!/usr/bin/env bash
set -u
case "${1-}" in
    --version-value) printf '0.2.1\n' ;;
    --generate-lock)
        shift
        output="$1"
        printf '%s\n' "$@" >"$WARI_DELEGATE_MARKER"
        printf 'delegated-lock\n' >"$output"
        ;;
    *) exit 2 ;;
esac
FAKE_WARI
    chmod 755 "$DELEGATE_ROOT/wari"
    set +e
    DELEGATE_OUTPUT="$(WARI_DELEGATE_MARKER="$DELEGATE_MARKER" \
        bash "$DELEGATE_ROOT/tools/generate-lock.sh" \
        0.2.1 1.12.7 2.8.11 static 2>/dev/null)"
    DELEGATE_STATUS=$?
    set -e
    assert_eq '0' "$DELEGATE_STATUS" \
        'maintainer lock tool delegates to the local Wari launcher'
    assert_eq 'delegated-lock' "$DELEGATE_OUTPUT" \
        'maintainer lock tool prints the canonical generator output'
    if [[ -f "$DELEGATE_MARKER" ]]; then
        assert_contains "$(<"$DELEGATE_MARKER")" '--frankenphp' \
            'maintainer lock tool forwards exact FrankenPHP selection'
        assert_contains "$(<"$DELEGATE_MARKER")" '--composer' \
            'maintainer lock tool forwards exact Composer selection'
    fi

    FAKE_BIN="$LOCK_TMP/fake-bin"
    GENERATED_LOCK="$LOCK_TMP/generated.lock"
    RETRY_MARKER="$LOCK_TMP/composer-checksum-first-attempt"
    mkdir -p "$FAKE_BIN"
    cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
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
    *api.github.com*)
        cp "$WARI_TEST_FIXTURES/frankenphp-release.json" "$destination"
        ;;
    https://composer.github.io/installer.sig)
        printf '%096d\n' 8 >"$destination"
        ;;
    */composer.phar.sha256sum)
        if [[ ! -e "$WARI_GENERATOR_RETRY_MARKER" ]]; then
            : >"$WARI_GENERATOR_RETRY_MARKER"
            exit 18
        fi
        printf '%064d  composer.phar\n' 7 >"$destination"
        ;;
    *) exit 22 ;;
esac
printf '%s' "$url"
FAKE_CURL
    chmod 755 "$FAKE_BIN/curl"

    set +e
    PATH="$FAKE_BIN:$PATH" WARI_GENERATOR_RETRY_MARKER="$RETRY_MARKER" \
        WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
        bash "$GENERATOR" 0.3.0 1.12.7 2.8.11 static >"$GENERATED_LOCK"
    GENERATOR_STATUS=$?
    set -e
    assert_eq '0' "$GENERATOR_STATUS" \
        'lock generator retries a transient partial download'
    if [[ "$GENERATOR_STATUS" -eq 0 ]]; then
        parse_lock "$GENERATED_LOCK"
        assert_eq '2.8.11' "$LOCK_COMPOSER_VERSION" \
            'retried generation emits a valid exact Composer lock'
    fi
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'lock generator exists'
fi

finish_tests
