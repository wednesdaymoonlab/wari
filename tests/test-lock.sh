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

FORMAT2_LOCK="$LOCK_TMP/format2.lock"
write_format2_lock "$FORMAT2_LOCK"
set +e
parse_lock "$FORMAT2_LOCK" >/dev/null 2>&1
FORMAT2_STATUS=$?
set -e
assert_eq '0' "$FORMAT2_STATUS" 'accepts a complete canonical format 2 lock'
if [[ "$FORMAT2_STATUS" -eq 0 ]]; then
    assert_eq '2' "$LOCK_VERSION" 'loads format 2 as the active lock format'
    assert_eq '0.4.0' "$LOCK_WARI_VERSION" 'loads the format 2 Wari version'
    assert_eq '1.12.7' "$LOCK_FRANKENPHP_VERSION" \
        'loads the format 2 FrankenPHP version'
    assert_eq '2.8.11' "$LOCK_COMPOSER_VERSION" \
        'loads the format 2 Composer version'
    assert_eq 'static' "$LOCK_LINUX_BUILD" 'loads the format 2 Linux build'
fi

FORMAT2_WITH_HASH="$LOCK_TMP/format2-with-hash.lock"
{
    cat "$FORMAT2_LOCK"
    printf 'wari_sha256=%064d\n' 0
} >"$FORMAT2_WITH_HASH"
set +e
FORMAT2_HASH_OUTPUT="$(parse_lock "$FORMAT2_WITH_HASH" 2>&1)"
FORMAT2_HASH_STATUS=$?
set -e
assert_eq '1' "$FORMAT2_HASH_STATUS" 'format 2 rejects legacy checksum keys'
assert_contains "$FORMAT2_HASH_OUTPUT" 'format 2 does not allow checksum keys' \
    'format 2 checksum rejection explains the schema boundary'

FORMAT2_REORDERED="$LOCK_TMP/format2-reordered.lock"
printf '%s\n' \
    'lock_version=2' \
    'frankenphp_version=1.12.7' \
    'wari_version=0.4.0' \
    'composer_version=2.8.11' \
    'linux_build=static' >"$FORMAT2_REORDERED"
assert_fails 'format 2 rejects keys outside canonical order' \
    parse_lock "$FORMAT2_REORDERED"

FORMAT2_BLANK="$LOCK_TMP/format2-blank.lock"
{
    sed -n '1,2p' "$FORMAT2_LOCK"
    printf '\n'
    sed -n '3,5p' "$FORMAT2_LOCK"
} >"$FORMAT2_BLANK"
assert_fails 'format 2 rejects blank lines' parse_lock "$FORMAT2_BLANK"

FORMAT2_CONTROL="$LOCK_TMP/format2-control.lock"
printf 'lock_version=2\nwari_version=0.4.0\r\nfrankenphp_version=1.12.7\ncomposer_version=2.8.11\nlinux_build=static\n' \
    >"$FORMAT2_CONTROL"
assert_fails 'format 2 rejects control characters' parse_lock "$FORMAT2_CONTROL"

FORMAT2_UNSUPPORTED="$LOCK_TMP/format2-unsupported.lock"
sed 's/^lock_version=2$/lock_version=3/' \
    "$FORMAT2_LOCK" >"$FORMAT2_UNSUPPORTED"
assert_fails 'rejects an unsupported lock format' parse_lock "$FORMAT2_UNSUPPORTED"

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
assert_eq '' "${ASSET_SHA256-}" \
    'asset selection does not trust the legacy Linux checksum'

parse_lock "$VALID_LOCK"
PLATFORM_OS='darwin'
PLATFORM_ARCH='arm64'
select_locked_asset
assert_eq 'frankenphp-mac-arm64' "$ASSET_NAME" \
    'selects the macOS Apple Silicon asset'
assert_eq '' "${ASSET_SHA256-}" \
    'asset selection does not trust the legacy macOS checksum'

LEGACY_CHANGED_SHA="$LOCK_TMP/legacy-changed-sha.lock"
write_format1_lock "$LOCK_TMP/legacy-current-version.lock" "$CORE_DIR/wari"
sed 's/^wari_sha256=.*/wari_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$LOCK_TMP/legacy-current-version.lock" >"$LEGACY_CHANGED_SHA"
set +e
if declare -F validate_launcher_lock_version >/dev/null 2>&1; then
    validate_launcher_lock_version "$CORE_DIR/wari" \
        "$LEGACY_CHANGED_SHA" >/dev/null 2>&1
    LEGACY_IDENTITY_STATUS=$?
else
    LEGACY_IDENTITY_STATUS=127
fi
set -e
assert_eq '0' "$LEGACY_IDENTITY_STATUS" \
    'legacy launcher checksum is not an identity input'

WRONG_VERSION="$LOCK_TMP/wrong-version.lock"
write_format2_lock "$WRONG_VERSION" 9.9.9
assert_fails 'launcher identity still requires the locked Wari version' \
    validate_launcher_pair "$CORE_DIR/wari" "$WRONG_VERSION"

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
        cp "${WARI_TEST_RELEASE_FIXTURE:-$WARI_TEST_FIXTURES/frankenphp-release.json}" \
            "$destination"
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
if [[ -n "${WARI_GENERATOR_REQUEST_LOG:-}" ]]; then
    printf '%s\n' "$url" >>"$WARI_GENERATOR_REQUEST_LOG"
fi
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

FORMAT2_GENERATED="$LOCK_TMP/generated-v2.lock"
FORMAT2_REQUEST_LOG="$LOCK_TMP/generated-v2-requests"
set +e
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    WARI_GENERATOR_REQUEST_LOG="$FORMAT2_REQUEST_LOG" \
    bash "$CORE_DIR/wari" --generate-lock "$FORMAT2_GENERATED" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static \
    --lock-version 2 >/dev/null 2>&1
FORMAT2_GENERATED_STATUS=$?
set -e
assert_eq '0' "$FORMAT2_GENERATED_STATUS" \
    'hidden generator creates an explicit format 2 lock'
if [[ "$FORMAT2_GENERATED_STATUS" -eq 0 ]]; then
    EXPECTED_FORMAT2="$(printf '%s\n' \
        'lock_version=2' \
        'wari_version=0.4.0' \
        'frankenphp_version=1.12.7' \
        'composer_version=2.8.11' \
        'linux_build=static')"
    assert_eq "$EXPECTED_FORMAT2" "$(<"$FORMAT2_GENERATED")" \
        'format 2 generator writes exactly five ordered keys'
fi
if [[ -f "$FORMAT2_REQUEST_LOG" ]]; then
    assert_not_contains "$(<"$FORMAT2_REQUEST_LOG")" \
        'composer.phar.sha256sum' \
        'format 2 generation does not fetch Composer artifact checksums'
    assert_not_contains "$(<"$FORMAT2_REQUEST_LOG")" \
        'composer.github.io/installer.sig' \
        'format 2 generation does not fetch the Composer installer signature'
fi

assert_fails 'lock generator rejects duplicate lock-version options' \
    bash "$CORE_DIR/wari" --generate-lock "$LOCK_TMP/duplicate-version.lock" \
    --lock-version 2 --lock-version 2
assert_fails 'lock generator rejects an unsupported output format' \
    bash "$CORE_DIR/wari" --generate-lock "$LOCK_TMP/unsupported-version.lock" \
    --lock-version 3

VERSION_ONLY_RELEASE="$LOCK_TMP/version-only-release.json"
cat >"$VERSION_ONLY_RELEASE" <<'VERSION_ONLY_JSON'
{
  "tag_name": "v1.12.7",
  "draft": false,
  "prerelease": false,
  "assets": []
}
VERSION_ONLY_JSON
set +e
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    WARI_TEST_RELEASE_FIXTURE="$VERSION_ONLY_RELEASE" \
    bash "$CORE_DIR/wari" --generate-lock "$LOCK_TMP/version-only-v2.lock" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static \
    --lock-version 2 >/dev/null 2>&1
VERSION_ONLY_STATUS=$?
set -e
assert_eq '0' "$VERSION_ONLY_STATUS" \
    'format 2 generation resolves versions without requiring artifact digests'

V030_CANDIDATE="$LOCK_TMP/v030-candidate.lock"
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    bash "$CORE_DIR/wari" --generate-lock "$V030_CANDIDATE" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static >/dev/null
assert_eq 'lock_version=1' "$(sed -n '1p' "$V030_CANDIDATE")" \
    'omitted lock version preserves the Wari 0.3.0 format 1 handshake'
assert_eq '12' "$(wc -l <"$V030_CANDIDATE" | tr -d ' ')" \
    'compatibility generator preserves the complete format 1 schema'
parse_lock "$V030_CANDIDATE"
assert_eq '1' "$LOCK_VERSION" 'Wari 0.4 reads its format 1 handshake output'

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
        assert_contains "$(<"$DELEGATE_MARKER")" '--lock-version' \
            'maintainer lock tool requests the current project lock format'
        assert_contains "$(<"$DELEGATE_MARKER")" $'--lock-version\n2' \
            'maintainer lock tool explicitly requests format 2'
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
        bash "$GENERATOR" 0.4.0 1.12.7 2.8.11 static >"$GENERATED_LOCK"
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
