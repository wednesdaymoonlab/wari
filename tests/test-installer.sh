#!/usr/bin/env bash
set -u
TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/test-helper.sh"
source "$CORE_DIR/install.sh"

assert_eq '0.4.0' "$WARI_VERSION" 'thin initializer reports its release version'
PIPE_HELP_OUTPUT="$(bash -s -- --help <"$CORE_DIR/install.sh")"
assert_contains "$PIPE_HELP_OUTPUT" 'Add the tracked Wari launcher and lock' \
    'pipe mode runs the project initializer'
assert_fails 'initializer rejects obsolete FrankenPHP version options' \
    initializer_main --version 1.12.7

TESTS_RUN=$((TESTS_RUN + 1))
if declare -F install_frankenphp >/dev/null 2>&1 ||
    declare -F generate_wrappers >/dev/null 2>&1 ||
    declare -F publish_install >/dev/null 2>&1; then
    fail 'initializer contains no runtime installation implementation'
else
    pass 'initializer contains no runtime installation implementation'
fi

NONINTERACTIVE="$(mktemp -d "${TMPDIR:-/tmp}/wari-installer-test.XXXXXX")"
trap 'rm -rf -- "$NONINTERACTIVE"' EXIT
set +e
NONINTERACTIVE_OUTPUT="$(cd "$NONINTERACTIVE" && initializer_main </dev/null 2>&1)"
NONINTERACTIVE_STATUS=$?
set -e
assert_eq '1' "$NONINTERACTIVE_STATUS" \
    'non-interactive initializer requires explicit consent'
assert_contains "$NONINTERACTIVE_OUTPUT" '--yes' \
    'non-interactive initializer explains the automation flag'
assert_contains "$NONINTERACTIVE_OUTPUT" '[FAIL]' \
    'initializer marks failures with the retro status label'
assert_eq '0' "$(test ! -e "$NONINTERACTIVE/.wari"; printf '%s' "$?")" \
    'initializer never creates a local runtime'
finish_tests
