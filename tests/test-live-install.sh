#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${WARI_RUN_LIVE:-0}" != '1' ]]; then
    printf 'live test skipped (set WARI_RUN_LIVE=1 to enable)\n'
    exit 0
fi

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"
LIVE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wari-live-test.XXXXXX")"
SERVER_PID=''

cleanup_live_test() {
    local status=$?
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    case "$LIVE_ROOT" in
        "${TMPDIR:-/tmp}"/wari-live-test.*) rm -rf -- "$LIVE_ROOT" ;;
        *) printf 'Refusing to remove unsafe live-test path: %s\n' "$LIVE_ROOT" >&2 ;;
    esac
    exit "$status"
}
trap cleanup_live_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if curl --silent --output /dev/null --max-time 1 'http://127.0.0.1:8000/' 2>/dev/null; then
    printf 'Port 8000 is already occupied; live test cannot safely run.\n' >&2
    exit 1
fi

PROJECT="$LIVE_ROOT/project"
mkdir -p "$PROJECT/public"
cp "$CORE_DIR/install.sh" "$PROJECT/install.sh"
printf '%s\n' '<?php echo "wari-live-ok";' >"$PROJECT/public/index.php"

(
    cd "$PROJECT"
    if [[ "${WARI_TRACE_INSTALL:-0}" == '1' ]]; then
        bash -x ./install.sh --yes --linux-build "${WARI_LINUX_BUILD:-static}"
    else
        bash ./install.sh --yes --linux-build "${WARI_LINUX_BUILD:-static}"
    fi
)

"$PROJECT/wari/php" --version
"$PROJECT/wari/composer" --version
"$PROJECT/wari/frankenphp" version
"$PROJECT/wari/php" -m >/dev/null
if [[ "$("$PROJECT/wari/php" -r 'echo $argv[1];' 'wari-eval-ok')" != 'wari-eval-ok' ]]; then
    printf 'PHP -r compatibility check failed.\n' >&2
    exit 1
fi

printf '%s\n' \
    '{' \
    '  "name": "wednesdaysmoonlab/wari-live-test",' \
    '  "scripts": {' \
    '    "plain-php": "php -r \"echo 12345;\"",' \
    '    "at-php": "@php -r \"echo 67890;\""' \
    '  }' \
    '}' >"$PROJECT/composer.json"

plain_script_output="$("$PROJECT/wari/composer" run plain-php --no-interaction 2>&1)"
if [[ "$plain_script_output" != *12345* ]]; then
    printf 'Composer plain php script failed:\n%s\n' "$plain_script_output" >&2
    exit 1
fi

at_php_output="$("$PROJECT/wari/composer" run at-php --no-interaction 2>&1)"
if [[ "$at_php_output" != *67890* ]]; then
    printf 'Composer @php script failed:\n%s\n' "$at_php_output" >&2
    exit 1
fi

(
    cd "$PROJECT"
    exec ./wari/serve
) >"$LIVE_ROOT/server.log" 2>&1 &
SERVER_PID=$!

response=''
attempt=0
while ((attempt < 40)); do
    if response="$(curl --silent --show-error --max-time 2 'http://127.0.0.1:8000/' 2>/dev/null)"; then
        break
    fi
    if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
        printf 'Wari server exited before becoming ready.\n' >&2
        sed -n '1,160p' "$LIVE_ROOT/server.log" >&2
        exit 1
    fi
    sleep 0.5
    attempt=$((attempt + 1))
done

if [[ "$response" != 'wari-live-ok' ]]; then
    printf 'Unexpected live response: %s\n' "$response" >&2
    sed -n '1,160p' "$LIVE_ROOT/server.log" >&2
    exit 1
fi

printf 'live install and HTTP smoke test passed\n'
