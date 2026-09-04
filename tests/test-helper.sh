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

finish_tests() {
    printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
