#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"

if ! declare -F generate_wrappers >/dev/null 2>&1; then
    fail 'wrapper generator exists'
    finish_tests
    exit $?
fi

WRAPPER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-wrapper-test.XXXXXX")"
WRAPPER_TMP="$(CDPATH= cd -- "$WRAPPER_TMP" && pwd -P)"
trap 'rm -rf -- "$WRAPPER_TMP"' EXIT
PROJECT="$WRAPPER_TMP/project with spaces"
WARI="$PROJECT/.wari"
DISPATCHER="$PROJECT/wari"
CAPTURE="$WRAPPER_TMP/capture"
mkdir -p "$WARI/runtime" "$PROJECT/nested/path"
printf '%s\n' 'Wari runtime layout 2' >"$WARI/.wari-owned"

{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '%s\n' 'printf '\''cwd=%s\n'\'' "$PWD" >"$FAKE_CAPTURE"'
    printf '%s\n' 'printf '\''argc=%s\n'\'' "$#" >>"$FAKE_CAPTURE"'
    printf '%s\n' 'index=0'
    printf '%s\n' 'for argument in "$@"; do'
    printf '%s\n' '  printf '\''arg%s=<%s>\n'\'' "$index" "$argument" >>"$FAKE_CAPTURE"'
    printf '%s\n' '  index=$((index + 1))'
    printf '%s\n' 'done'
    printf '%s\n' 'printf '\''php_binary=%s\npath=%s\nwari_composer_context=%s\nxdg_config_home=%s\nxdg_data_home=%s\n'\'' "${PHP_BINARY-}" "$PATH" "${WARI_COMPOSER_CONTEXT-}" "${XDG_CONFIG_HOME-}" "${XDG_DATA_HOME-}" >>"$FAKE_CAPTURE"'
    printf '%s\n' 'case "${1-}/${2-}/${3-}" in'
    printf '%s\n' '  php-cli/*php-proxy.php/version) printf '\''PHP 8.4.0 (cli)\n'\''; exit 0 ;;'
    printf '%s\n' '  php-cli/*composer.phar/--version)'
    printf '%s\n' '    printf '\''%s\n'\'' '\''PHP version 8.5.10 (/fixture/runtime/composer.phar)'\'' '\''Run the "diagnose" command to get more detailed diagnostics output.'\'' '\''Composer warning remains visible.'\'' >&2'
    printf '%s\n' '    printf '\''Composer version 2.8.11 2025-01-01\n'\''; exit 0 ;;'
    printf '%s\n' '  version//) printf '\''FrankenPHP v1.12.7\n'\''; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit "${FAKE_EXIT_CODE:-0}"'
} >"$WARI/runtime/frankenphp"
chmod 755 "$WARI/runtime/frankenphp"
printf 'fake composer' >"$WARI/runtime/composer.phar"

generate_wrappers "$WARI"
cp "$CORE_DIR/wari" "$DISPATCHER"
cp "$CORE_DIR/wari.lock" "$PROJECT/wari.lock"
chmod 755 "$DISPATCHER"
DISPATCHER_SHA="$(calculate_checksum sha256 "$DISPATCHER")"
sed "s/^wari_sha256=.*/wari_sha256=$DISPATCHER_SHA/" \
    "$PROJECT/wari.lock" >"$PROJECT/wari.lock.next"
mv -- "$PROJECT/wari.lock.next" "$PROJECT/wari.lock"

case "$(uname -s)" in
    Linux) TEST_OS='linux' ;;
    Darwin) TEST_OS='darwin' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) TEST_ARCH='x86_64' ;;
    arm64|aarch64) TEST_ARCH='arm64' ;;
esac
if [[ "$TEST_OS" == 'linux' ]]; then
    TEST_LINUX_BUILD='"static"'
else
    TEST_LINUX_BUILD='null'
fi
LOCK_SHA="$(lock_digest "$PROJECT/wari.lock")"
cat >"$WARI/manifest.json" <<EOF
{
  "layout_version": 2,
  "lock_sha256": "$LOCK_SHA",
  "wari_version": "0.3.0",
  "frankenphp_version": "1.12.7",
  "php_version": "8.4.0",
  "composer_version": "2.8.11",
  "os": "$TEST_OS",
  "architecture": "$TEST_ARCH",
  "linux_build": $TEST_LINUX_BUILD,
  "checksum_verified": true,
  "slsa_verified": false
}
EOF

(
    cd "$PROJECT/nested/path"
    FAKE_CAPTURE="$CAPTURE" "$WARI/php" alpha 'two words' '*'
)
PHP_CAPTURE="$(<"$CAPTURE")"
assert_contains "$PHP_CAPTURE" "cwd=$PROJECT/nested/path" 'PHP wrapper preserves caller working directory'
assert_contains "$PHP_CAPTURE" 'arg0=<php-cli>' 'PHP wrapper selects php-cli'
assert_contains "$PHP_CAPTURE" 'arg1=<alpha>' 'PHP wrapper forwards first argument'
assert_contains "$PHP_CAPTURE" 'arg2=<two words>' 'PHP wrapper preserves spaces'
assert_contains "$PHP_CAPTURE" 'arg3=<*>' 'PHP wrapper does not expand glob arguments'
assert_contains "$PHP_CAPTURE" "php_binary=$WARI/php" 'PHP wrapper exports itself as PHP_BINARY for child processes'
assert_contains "$PHP_CAPTURE" "path=$WARI:" 'PHP wrapper prepends itself to PATH for child processes'

FAKE_CAPTURE="$CAPTURE" "$WARI/php" --version
VERSION_CAPTURE="$(<"$CAPTURE")"
assert_contains "$VERSION_CAPTURE" "arg1=<$WARI/runtime/php-proxy.php>" 'PHP version uses compatibility helper'
assert_contains "$VERSION_CAPTURE" 'arg2=<version>' 'PHP version selects helper version mode'

FAKE_CAPTURE="$CAPTURE" "$WARI/php" -r 'echo $argv[1];' hello
EVAL_CAPTURE="$(<"$CAPTURE")"
assert_contains "$EVAL_CAPTURE" "arg1=<$WARI/runtime/php-proxy.php>" 'PHP -r uses compatibility helper'
assert_contains "$EVAL_CAPTURE" 'arg2=<eval>' 'PHP -r selects helper eval mode'
assert_contains "$EVAL_CAPTURE" 'arg3=<echo $argv[1];>' 'PHP -r preserves source code argument'
assert_contains "$EVAL_CAPTURE" 'arg4=<hello>' 'PHP -r preserves script arguments'

FAKE_CAPTURE="$CAPTURE" "$WARI/php" -m
MODULE_CAPTURE="$(<"$CAPTURE")"
assert_contains "$MODULE_CAPTURE" 'arg2=<modules>' 'PHP -m selects helper modules mode'

FAKE_CAPTURE="$CAPTURE" "$WARI/php" -i
INFO_CAPTURE="$(<"$CAPTURE")"
assert_contains "$INFO_CAPTURE" 'arg2=<info>' 'PHP -i selects helper info mode'

FAKE_CAPTURE="$CAPTURE" "$WARI/php" -d memory_limit=-1 -ddisplay_errors=1 script.php 2>"$WRAPPER_TMP/php-warning"
FILTER_CAPTURE="$(<"$CAPTURE")"
assert_contains "$FILTER_CAPTURE" 'argc=2' 'PHP wrapper removes both -d forms'
assert_contains "$FILTER_CAPTURE" 'arg1=<script.php>' 'PHP wrapper retains script after -d options'
assert_contains "$(<"$WRAPPER_TMP/php-warning")" 'memory_limit=-1' 'PHP wrapper warns for split -d value'
assert_contains "$(<"$WRAPPER_TMP/php-warning")" 'display_errors=1' 'PHP wrapper warns for joined -d value'
assert_fails 'PHP wrapper rejects bare -d' env FAKE_CAPTURE="$CAPTURE" "$WARI/php" -d

FAKE_CAPTURE="$CAPTURE" WARI_COMPOSER_CONTEXT=1 "$WARI/php" -d memory_limit=1536M -ddisplay_errors=1 script.php 2>"$WRAPPER_TMP/composer-php-warning"
assert_eq '' "$(<"$WRAPPER_TMP/composer-php-warning")" 'PHP wrapper suppresses unsupported -d warnings in Composer context'

(
    cd "$PROJECT/nested/path"
    unset HOME XDG_CONFIG_HOME XDG_DATA_HOME
    FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S 127.0.0.1:8080 router.php
)
SERVER_CAPTURE="$(<"$CAPTURE")"
assert_contains "$SERVER_CAPTURE" 'arg0=<php-server>' 'PHP -S selects FrankenPHP server mode'
assert_contains "$SERVER_CAPTURE" 'arg1=<--listen>' 'PHP -S supplies listen option'
assert_contains "$SERVER_CAPTURE" 'arg2=<127.0.0.1:8080>' 'PHP -S preserves listen address'
assert_contains "$SERVER_CAPTURE" 'arg3=<--root>' 'PHP -S supplies document root option'
assert_contains "$SERVER_CAPTURE" "arg4=<$PROJECT/nested/path>" 'PHP -S defaults document root to caller directory'
assert_contains "$SERVER_CAPTURE" 'argc=5' 'PHP -S consumes optional router compatibility hint'
assert_contains "$SERVER_CAPTURE" "xdg_config_home=$WARI/runtime/xdg/config" 'PHP -S supplies local XDG config when HOME is unavailable'
assert_contains "$SERVER_CAPTURE" "xdg_data_home=$WARI/runtime/xdg/data" 'PHP -S supplies local XDG data when HOME is unavailable'

mkdir -p "$PROJECT/nested/path/custom public"
(
    cd "$PROJECT/nested/path"
    FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S localhost:9090 -t 'custom public' router.php
)
SERVER_DOCROOT_CAPTURE="$(<"$CAPTURE")"
assert_contains "$SERVER_DOCROOT_CAPTURE" "arg4=<$PROJECT/nested/path/custom public>" 'PHP -S resolves custom document root from caller directory'
assert_fails 'PHP -S rejects a missing listen address' env FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S
assert_fails 'PHP -S rejects -t without a document root' env FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S localhost:8080 -t
assert_fails 'PHP -S rejects a document root that does not exist' env FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S localhost:8080 -t missing
assert_fails 'PHP -S rejects more than one router argument' env FAKE_CAPTURE="$CAPTURE" "$WARI/php" -S localhost:8080 router.php extra.php

FAKE_CAPTURE="$CAPTURE" "$WARI/composer" require 'vendor/package'
COMPOSER_CAPTURE="$(<"$CAPTURE")"
assert_contains "$COMPOSER_CAPTURE" 'arg0=<php-cli>' 'Composer runs through PHP CLI'
assert_contains "$COMPOSER_CAPTURE" "arg1=<$WARI/runtime/composer.phar>" 'Composer uses project-local PHAR'
assert_contains "$COMPOSER_CAPTURE" 'arg2=<require>' 'Composer forwards command'
assert_contains "$COMPOSER_CAPTURE" "php_binary=$WARI/php" 'Composer exports PHP_BINARY'
assert_contains "$COMPOSER_CAPTURE" "path=$WARI:" 'Composer prepends Wari to PATH'
assert_contains "$COMPOSER_CAPTURE" 'wari_composer_context=1' 'Composer marks its process tree for PHP compatibility'

FAKE_CAPTURE="$CAPTURE" "$WARI/composer" --version \
    >"$WRAPPER_TMP/composer-version.stdout" \
    2>"$WRAPPER_TMP/composer-version.stderr"
assert_contains "$(<"$WRAPPER_TMP/composer-version.stdout")" \
    'Composer version 2.8.11' \
    'Composer version command preserves its primary output'
if [[ "$(<"$WRAPPER_TMP/composer-version.stderr")" == *'PHP version 8.5.10'* || \
    "$(<"$WRAPPER_TMP/composer-version.stderr")" == *'Run the "diagnose" command'* ]]; then
    WRAPPER_HAS_COMPOSER_FOOTER=1
else
    WRAPPER_HAS_COMPOSER_FOOTER=0
fi
assert_eq '0' "$WRAPPER_HAS_COMPOSER_FOOTER" \
    'Composer version wrapper hides the informational version footer'
assert_contains "$(<"$WRAPPER_TMP/composer-version.stderr")" \
    'Composer warning remains visible.' \
    'Composer version wrapper preserves unrelated diagnostics'

assert_fails 'serve rejects a project without public directory' env FAKE_CAPTURE="$CAPTURE" "$WARI/serve"
mkdir -p "$PROJECT/public"
(
    unset HOME XDG_CONFIG_HOME XDG_DATA_HOME
    FAKE_CAPTURE="$CAPTURE" "$WARI/serve"
)
SERVE_CAPTURE="$(<"$CAPTURE")"
assert_contains "$SERVE_CAPTURE" 'arg0=<php-server>' 'serve selects php-server'
assert_contains "$SERVE_CAPTURE" 'arg1=<--listen>' 'serve supplies listen option'
assert_contains "$SERVE_CAPTURE" 'arg2=<127.0.0.1:8000>' 'serve binds to loopback port 8000'
assert_contains "$SERVE_CAPTURE" "arg4=<$PROJECT/public>" 'serve supplies absolute public root'
assert_contains "$SERVE_CAPTURE" "xdg_config_home=$WARI/runtime/xdg/config" \
    'serve supplies local XDG config without HOME'
assert_contains "$SERVE_CAPTURE" "xdg_data_home=$WARI/runtime/xdg/data" \
    'serve supplies local XDG data without HOME'

FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" run --config 'My Caddyfile'
RAW_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_CAPTURE" 'arg0=<run>' 'raw wrapper forwards command'
assert_contains "$RAW_CAPTURE" 'arg2=<My Caddyfile>' 'raw wrapper preserves config path'

(
    unset HOME XDG_CONFIG_HOME XDG_DATA_HOME
    FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" version
)
RAW_NO_HOME_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_NO_HOME_CAPTURE" "xdg_config_home=$WARI/runtime/xdg/config" \
    'FrankenPHP wrapper supplies local XDG config without HOME'
assert_contains "$RAW_NO_HOME_CAPTURE" "xdg_data_home=$WARI/runtime/xdg/data" \
    'FrankenPHP wrapper supplies local XDG data without HOME'

(
    unset HOME
    XDG_CONFIG_HOME='/srv/wari state/config' \
    XDG_DATA_HOME='/srv/wari state/data' \
    FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" version
)
RAW_EXPLICIT_XDG_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_EXPLICIT_XDG_CAPTURE" \
    'xdg_config_home=/srv/wari state/config' \
    'FrankenPHP wrapper preserves explicit XDG config'
assert_contains "$RAW_EXPLICIT_XDG_CAPTURE" \
    'xdg_data_home=/srv/wari state/data' \
    'FrankenPHP wrapper preserves explicit XDG data'

(
    HOME='/srv/service-home' \
    XDG_CONFIG_HOME= XDG_DATA_HOME= \
    FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" version
)
RAW_HOME_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_HOME_CAPTURE" 'xdg_config_home=' \
    'FrankenPHP wrapper does not invent XDG config when HOME is available'
assert_contains "$RAW_HOME_CAPTURE" 'xdg_data_home=' \
    'FrankenPHP wrapper does not invent XDG data when HOME is available'

set +e
FAKE_CAPTURE="$CAPTURE" FAKE_EXIT_CODE=17 "$WARI/php" script.php >/dev/null 2>&1
WRAPPER_STATUS=$?
set -e
assert_eq '17' "$WRAPPER_STATUS" 'PHP wrapper forwards runtime exit code'

(
    cd "$PROJECT/nested/path"
    FAKE_CAPTURE="$CAPTURE" "$DISPATCHER" php alpha 'two words' '*'
)
DISPATCH_PHP_CAPTURE="$(<"$CAPTURE")"
assert_contains "$DISPATCH_PHP_CAPTURE" "cwd=$PROJECT" 'dispatcher PHP command changes to project root'
assert_contains "$DISPATCH_PHP_CAPTURE" 'arg1=<alpha>' 'dispatcher PHP command forwards arguments'
assert_contains "$DISPATCH_PHP_CAPTURE" 'arg2=<two words>' 'dispatcher preserves spaces'
assert_contains "$DISPATCH_PHP_CAPTURE" 'arg3=<*>' 'dispatcher does not expand glob arguments'

FAKE_CAPTURE="$CAPTURE" "$DISPATCHER" composer require 'vendor/package'
DISPATCH_COMPOSER_CAPTURE="$(<"$CAPTURE")"
assert_contains "$DISPATCH_COMPOSER_CAPTURE" "arg1=<$WARI/runtime/composer.phar>" 'dispatcher Composer command uses hidden runtime'
assert_contains "$DISPATCH_COMPOSER_CAPTURE" 'arg2=<require>' 'dispatcher Composer command forwards arguments'
assert_contains "$DISPATCH_COMPOSER_CAPTURE" "php_binary=$WARI/php" 'dispatcher Composer command exports hidden PHP_BINARY'
assert_contains "$DISPATCH_COMPOSER_CAPTURE" "path=$WARI:" 'dispatcher Composer command prepends hidden runtime to PATH'

FAKE_CAPTURE="$CAPTURE" "$DISPATCHER" serve
DISPATCH_SERVE_CAPTURE="$(<"$CAPTURE")"
assert_contains "$DISPATCH_SERVE_CAPTURE" 'arg0=<php-server>' 'dispatcher serve command selects PHP server'

FAKE_CAPTURE="$CAPTURE" "$DISPATCHER" frankenphp run --config 'My Caddyfile'
DISPATCH_RAW_CAPTURE="$(<"$CAPTURE")"
assert_contains "$DISPATCH_RAW_CAPTURE" 'arg0=<run>' 'dispatcher FrankenPHP command forwards command'
assert_contains "$DISPATCH_RAW_CAPTURE" 'arg2=<My Caddyfile>' 'dispatcher FrankenPHP command preserves config path'

for help_argument in '' help --help -h; do
    if [[ -n "$help_argument" ]]; then
        HELP_OUTPUT="$("$DISPATCHER" "$help_argument")"
    else
        HELP_OUTPUT="$("$DISPATCHER")"
    fi
    assert_contains "$HELP_OUTPUT" 'php' "dispatcher $help_argument help lists PHP"
    assert_contains "$HELP_OUTPUT" 'composer' "dispatcher $help_argument help lists Composer"
    assert_contains "$HELP_OUTPUT" 'serve' "dispatcher $help_argument help lists serve"
    assert_contains "$HELP_OUTPUT" 'frankenphp' "dispatcher $help_argument help lists FrankenPHP"
done

printf 'not-invoked' >"$CAPTURE"
set +e
UNKNOWN_OUTPUT="$(FAKE_CAPTURE="$CAPTURE" "$DISPATCHER" unknown 2>&1)"
UNKNOWN_STATUS=$?
set -e
assert_eq '1' "$UNKNOWN_STATUS" 'dispatcher rejects unknown command'
assert_contains "$UNKNOWN_OUTPUT" 'unknown Wari command: unknown' 'dispatcher identifies unknown command'
assert_contains "$UNKNOWN_OUTPUT" 'Usage:' 'dispatcher prints usage for unknown command'
assert_eq 'not-invoked' "$(<"$CAPTURE")" 'dispatcher does not invoke runtime for unknown command'

ORPHAN_PROJECT="$WRAPPER_TMP/orphan"
mkdir -p "$ORPHAN_PROJECT"
cp "$DISPATCHER" "$ORPHAN_PROJECT/wari"
cp "$PROJECT/wari.lock" "$ORPHAN_PROJECT/wari.lock"
set +e
MISSING_OUTPUT="$("$ORPHAN_PROJECT/wari" php --version 2>&1)"
MISSING_STATUS=$?
set -e
assert_eq '1' "$MISSING_STATUS" 'dispatcher rejects missing hidden runtime'
assert_contains "$MISSING_OUTPUT" './wari setup' 'dispatcher explains missing hidden runtime'

set +e
FAKE_CAPTURE="$CAPTURE" FAKE_EXIT_CODE=17 "$DISPATCHER" php script.php >/dev/null 2>&1
DISPATCH_STATUS=$?
set -e
assert_eq '17' "$DISPATCH_STATUS" 'dispatcher forwards delegated exit code'

finish_tests
