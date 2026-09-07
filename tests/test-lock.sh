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
            'wari_version=0.2.0' \
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
assert_eq '0.2.0' "$LOCK_WARI_VERSION" 'loads the locked Wari version'
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

GENERATOR="$CORE_DIR/tools/generate-lock.sh"
if [[ -f "$GENERATOR" ]]; then
    GENERATOR_HELP="$(bash "$GENERATOR" --help)"
    assert_contains "$GENERATOR_HELP" \
        'generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>' \
        'lock generator documents its exact inputs'
    assert_fails 'lock generator rejects an incomplete version' \
        bash "$GENERATOR" 0.2 1.12.7 2.8.11 static
    assert_fails 'lock generator rejects an invalid Linux build' \
        bash "$GENERATOR" 0.2.0 1.12.7 2.8.11 dynamic

    FAKE_BIN="$LOCK_TMP/fake-bin"
    GENERATED_LOCK="$LOCK_TMP/generated.lock"
    RETRY_MARKER="$LOCK_TMP/composer-phar-first-attempt"
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
        {
            printf '{\n'
            for asset in \
                frankenphp-linux-x86_64 frankenphp-linux-aarch64 \
                frankenphp-mac-x86_64 frankenphp-mac-arm64; do
                printf '  "name": "%s",\n' "$asset"
                printf '  "digest": "sha256:%064d",\n' 7
                printf '  "browser_download_url": "https://github.com/php/frankenphp/releases/download/v1.12.7/%s",\n' "$asset"
            done
            printf '}\n'
        } >"$destination"
        ;;
    */installer)
        printf 'composer installer' >"$destination"
        ;;
    */composer.phar)
        if [[ ! -e "$WARI_GENERATOR_RETRY_MARKER" ]]; then
            : >"$WARI_GENERATOR_RETRY_MARKER"
            exit 18
        fi
        printf 'composer phar' >"$destination"
        ;;
    *) exit 22 ;;
esac
FAKE_CURL
    chmod 755 "$FAKE_BIN/curl"

    set +e
    PATH="$FAKE_BIN:$PATH" WARI_GENERATOR_RETRY_MARKER="$RETRY_MARKER" \
        bash "$GENERATOR" 0.2.0 1.12.7 2.8.11 static >"$GENERATED_LOCK"
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
