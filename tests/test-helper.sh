#!/usr/bin/env bash

set -u

TESTS_RUN=0
TESTS_FAILED=0

pass() {
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        pass "$message"
    else
        fail "$message (expected: $expected, actual: $actual)"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing: $needle)"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (unexpected: $needle)"
    fi
}

assert_fails() {
    local message="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$@" >/dev/null 2>&1 ); then
        fail "$message"
    else
        pass "$message"
    fi
}

test_file_sha256() {
    local path="$1"
    local output

    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum "$path")" || return 1
    else
        output="$(shasum -a 256 "$path")" || return 1
    fi
    printf '%s\n' "${output%%[[:space:]]*}"
}

write_format2_lock() {
    local path="$1"
    local wari_version="${2:-0.4.2}"
    local frankenphp_version="${3:-1.12.7}"
    local composer_version="${4:-2.8.11}"
    local linux_build="${5:-static}"

    printf '%s\n' \
        'lock_version=2' \
        "wari_version=$wari_version" \
        "frankenphp_version=$frankenphp_version" \
        "composer_version=$composer_version" \
        "linux_build=$linux_build" >"$path"
}

write_format1_lock() {
    local path="$1"
    local launcher="$2"
    local wari_version="${3:-0.4.2}"
    local frankenphp_version="${4:-1.12.7}"
    local composer_version="${5:-2.8.11}"
    local linux_build="${6:-static}"
    local launcher_sha

    launcher_sha="$(test_file_sha256 "$launcher")" || return 1
    {
        printf '%s\n' \
            'lock_version=1' \
            "wari_version=$wari_version" \
            "frankenphp_version=$frankenphp_version" \
            "composer_version=$composer_version" \
            "linux_build=$linux_build"
        printf 'wari_sha256=%s\n' "$launcher_sha"
        printf 'composer_installer_sha384=%096d\n' 0
        printf 'composer_sha256=%064d\n' 1
        printf 'frankenphp_linux_x86_64_sha256=%064d\n' 2
        printf 'frankenphp_linux_arm64_sha256=%064d\n' 3
        printf 'frankenphp_macos_x86_64_sha256=%064d\n' 4
        printf 'frankenphp_macos_arm64_sha256=%064d\n' 5
    } >"$path"
}

finish_tests() {
    printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
