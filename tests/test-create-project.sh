#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"

CREATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-create-project-test.XXXXXX")"
CREATE_TMP="$(CDPATH= cd -- "$CREATE_TMP" && pwd -P)"
trap 'rm -rf -- "$CREATE_TMP"' EXIT

read_file_or_empty() {
    local path="$1"
    if [[ -f "$path" ]]; then
        printf '%s' "$(<"$path")"
    fi
    return 0
}

make_create_project_fixture() {
    local project="$1"
    local wari="$project/.wari"

    mkdir -p "$wari/runtime"
    printf 'fake composer\n' >"$wari/runtime/composer.phar"
    cat >"$wari/runtime/frankenphp" <<'FAKE_FRANKENPHP'
#!/usr/bin/env bash
case "${1-}/${2-}/${3-}" in
    php-cli/*php-proxy.php/version) printf 'PHP 8.4.0 (cli)\n' ;;
    php-cli/*composer.phar/--version) printf 'Composer version 2.8.11 2025-01-01\n' ;;
    version//) printf 'FrankenPHP v1.12.7\n' ;;
esac
exit 0
FAKE_FRANKENPHP
    chmod 755 "$wari/runtime/frankenphp"
    generate_wrappers "$wari"
    cp "$CORE_DIR/wari" "$project/wari"
    cp "$CORE_DIR/wari.lock" "$project/wari.lock"
    chmod 755 "$project/wari"
    write_wari_ignore_block_for_test >"$project/.gitignore"
    printf '%s\n' 'Wari runtime layout 2' >"$wari/.wari-owned"

    local test_os test_arch linux_build_json lock_sha
    case "$(uname -s)" in Linux) test_os='linux' ;; Darwin) test_os='darwin' ;; esac
    case "$(uname -m)" in x86_64|amd64) test_arch='x86_64' ;; arm64|aarch64) test_arch='arm64' ;; esac
    if [[ "$test_os" == 'linux' ]]; then linux_build_json='"static"'; else linux_build_json='null'; fi
    lock_sha="$(lock_digest "$project/wari.lock")"
    cat >"$wari/manifest.json" <<EOF
{
  "layout_version": 2,
  "lock_sha256": "$lock_sha",
  "wari_version": "0.2.0",
  "frankenphp_version": "1.12.7",
  "php_version": "8.4.0",
  "composer_version": "2.8.11",
  "os": "$test_os",
  "architecture": "$test_arch",
  "linux_build": $linux_build_json,
  "checksum_verified": true,
  "slsa_verified": false
}
EOF
}

write_wari_ignore_block_for_test() {
    printf '%s\n' \
        '# Wari local runtime' '/.wari/' '/.wari-install.*' \
        '/.wari-backup.*' '/.wari-update.*' '/.wari-setup.lock'
}

write_fake_composer() {
    local destination="$1"

    cat >"$destination" <<'FAKE_COMPOSER'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1-}" == '--version' ]]; then
    printf 'Composer version 2.8.11 2025-01-01\n'
    exit 0
fi

capture="${FAKE_COMPOSER_CAPTURE:?}"
printf 'argc=%s\n' "$#" >"$capture"
index=0
for argument in "$@"; do
    printf 'arg%s=<%s>\n' "$index" "$argument" >>"$capture"
    index=$((index + 1))
done

target="${3-}"
case "${FAKE_COMPOSER_MODE:-success}" in
    fail)
        exit "${FAKE_COMPOSER_EXIT:-17}"
        ;;
    missing-composer-json)
        printf 'generated\n' >"$target/generated.txt"
        ;;
    wari-collision)
        printf '{}\n' >"$target/composer.json"
        printf 'collision\n' >"$target/wari"
        ;;
    runtime-collision)
        printf '{}\n' >"$target/composer.json"
        mkdir "$target/.wari"
        ;;
    concurrent-entry)
        printf '{"name":"vendor/project"}\n' >"$target/composer.json"
        printf 'generated\n' >"$target/generated.txt"
        printf 'unrelated\n' >"${FAKE_PROJECT_ROOT:?}/concurrent.txt"
        ;;
    block)
        printf '%s\n%s\n' "$target" "$$" >"${FAKE_BLOCK_CAPTURE:?}"
        trap 'exit 130' INT
        trap 'exit 143' TERM
        while :; do sleep 1; done
        ;;
    success)
        printf '{"name":"vendor/project"}\n' >"$target/composer.json"
        printf 'visible\n' >"$target/generated.txt"
        printf 'hidden\n' >"$target/.env"
        mkdir -p "$target/src" "$target/.git"
        printf '<?php\n' >"$target/src/App.php"
        printf '[core]\n' >"$target/.git/config"
        ;;
    success-gitignore)
        printf '{"name":"vendor/project"}\n' >"$target/composer.json"
        printf '/vendor/\n' >"$target/.gitignore"
        ;;
esac
FAKE_COMPOSER
    chmod 755 "$destination"
}

PROJECT="$CREATE_TMP/php app"
WARI="$PROJECT/.wari"
DISPATCHER="$PROJECT/wari"
make_create_project_fixture "$PROJECT"

assert_eq '4' "$(find "$PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'create-project fixture starts with four managed root entries'
assert_eq '0' "$(test -x "$WARI/create-project"; printf '%s' "$?")" \
    'wrapper generator creates executable create-project command'

printf '/custom-rule/\n' >>"$PROJECT/.gitignore"
set +e
CUSTOM_IGNORE_OUTPUT="$("$DISPATCHER" create-project --yes vendor/project 2>&1)"
CUSTOM_IGNORE_STATUS=$?
set -e
assert_eq '1' "$CUSTOM_IGNORE_STATUS" \
    'create-project rejects custom bootstrap ignore content'
assert_contains "$CUSTOM_IGNORE_OUTPUT" 'bootstrap .gitignore is invalid' \
    'custom bootstrap ignore failure is explicit'
assert_contains "$(<"$PROJECT/.gitignore")" '/custom-rule/' \
    'create-project preserves rejected custom ignore content'
write_wari_ignore_block_for_test >"$PROJECT/.gitignore"

HELP_OUTPUT="$("$DISPATCHER" --help)"
assert_contains "$HELP_OUTPUT" 'create-project' 'dispatcher help lists create-project'

set +e
COMMAND_HELP="$("$DISPATCHER" create-project --help 2>&1)"
COMMAND_HELP_STATUS=$?
set -e
assert_eq '0' "$COMMAND_HELP_STATUS" 'create-project help exits successfully'
assert_contains "$COMMAND_HELP" \
    'Usage: ./wari create-project [--yes] <package> [version] [composer-options]' \
    'create-project has focused usage help'

set +e
MISSING_OUTPUT="$("$DISPATCHER" create-project --yes 2>&1)"
MISSING_STATUS=$?
set -e
assert_eq '2' "$MISSING_STATUS" 'create-project rejects a missing package'
assert_contains "$MISSING_OUTPUT" 'Usage:' 'missing package prints usage'

printf 'existing data\n' >"$PROJECT/README.md"
set +e
NONEMPTY_OUTPUT="$("$DISPATCHER" create-project --yes vendor/project 2>&1)"
NONEMPTY_STATUS=$?
set -e
assert_eq '1' "$NONEMPTY_STATUS" 'create-project rejects an additional root entry'
assert_contains "$NONEMPTY_OUTPUT" 'README.md' 'preflight identifies the additional entry'
rm -f -- "$PROJECT/README.md"

ln -s missing-target "$PROJECT/extra-link"
set +e
BROKEN_LINK_OUTPUT="$("$DISPATCHER" create-project --yes vendor/project 2>&1)"
BROKEN_LINK_STATUS=$?
set -e
assert_eq '1' "$BROKEN_LINK_STATUS" 'create-project rejects a broken root symlink'
assert_contains "$BROKEN_LINK_OUTPUT" 'extra-link' 'preflight identifies a broken root symlink'
rm -f -- "$PROJECT/extra-link"

INCOMPLETE_PROJECT="$CREATE_TMP/incomplete-runtime"
make_create_project_fixture "$INCOMPLETE_PROJECT"
rm -f -- "$INCOMPLETE_PROJECT/.wari/runtime/composer.phar"
set +e
INCOMPLETE_OUTPUT="$(
    "$INCOMPLETE_PROJECT/wari" create-project --yes vendor/project 2>&1
)"
INCOMPLETE_STATUS=$?
set -e
assert_eq '1' "$INCOMPLETE_STATUS" 'create-project rejects an incomplete runtime'
assert_contains "$INCOMPLETE_OUTPUT" 'incomplete' \
    'incomplete runtime failure is explicit'

NONEXEC_PROJECT="$CREATE_TMP/nonexec-dispatcher"
make_create_project_fixture "$NONEXEC_PROJECT"
chmod 644 "$NONEXEC_PROJECT/wari"
set +e
NONEXEC_OUTPUT="$(
    "$NONEXEC_PROJECT/.wari/create-project" --yes vendor/project 2>&1
)"
NONEXEC_STATUS=$?
set -e
assert_eq '1' "$NONEXEC_STATUS" 'create-project rejects a non-executable dispatcher'
assert_contains "$NONEXEC_OUTPUT" 'Wari dispatcher is invalid' \
    'non-executable dispatcher failure is explicit'

SYMLINK_DISPATCHER_PROJECT="$CREATE_TMP/symlink-dispatcher"
make_create_project_fixture "$SYMLINK_DISPATCHER_PROJECT"
mv -- "$SYMLINK_DISPATCHER_PROJECT/wari" "$CREATE_TMP/real-dispatcher"
ln -s "$CREATE_TMP/real-dispatcher" "$SYMLINK_DISPATCHER_PROJECT/wari"
set +e
SYMLINK_DISPATCHER_OUTPUT="$(
    "$SYMLINK_DISPATCHER_PROJECT/.wari/create-project" --yes vendor/project 2>&1
)"
SYMLINK_DISPATCHER_STATUS=$?
set -e
assert_eq '1' "$SYMLINK_DISPATCHER_STATUS" \
    'create-project rejects a symbolic-link dispatcher'
assert_contains "$SYMLINK_DISPATCHER_OUTPUT" 'Wari dispatcher is invalid' \
    'symbolic-link dispatcher failure is explicit'

SYMLINK_RUNTIME_PROJECT="$CREATE_TMP/symlink-runtime"
make_create_project_fixture "$SYMLINK_RUNTIME_PROJECT"
SYMLINK_RUNTIME_TARGET="$CREATE_TMP/symlink-runtime-target"
mv -- "$SYMLINK_RUNTIME_PROJECT/.wari" "$SYMLINK_RUNTIME_TARGET"
ln -s "$SYMLINK_RUNTIME_TARGET" "$SYMLINK_RUNTIME_PROJECT/.wari"
set +e
SYMLINK_RUNTIME_OUTPUT="$(
    "$SYMLINK_RUNTIME_PROJECT/wari" create-project --yes vendor/project 2>&1
)"
SYMLINK_RUNTIME_STATUS=$?
set -e
assert_eq '1' "$SYMLINK_RUNTIME_STATUS" 'create-project rejects a symbolic-link runtime'
assert_contains "$SYMLINK_RUNTIME_OUTPUT" 'not recognized' \
    'symbolic-link runtime failure is explicit'

SOURCEABLE_CREATE_PROJECT="$CREATE_TMP/create-project-functions"
sed '$d' "$WARI/create-project" >"$SOURCEABLE_CREATE_PROJECT"

run_confirmation() (
    local answer="$1"
    local output="$2"

    # shellcheck disable=SC1090
    source "$SOURCEABLE_CREATE_PROJECT"
    PROJECT_ROOT="$PROJECT"
    printf '%s\n' "$answer" >"$CREATE_TMP/confirm.in"
    exec 3<"$CREATE_TMP/confirm.in" 4>"$output"
    confirm_create_project
)

CONFIRM_Y_OUTPUT="$CREATE_TMP/confirm-y.out"
assert_eq '0' "$(run_confirmation 'y' "$CONFIRM_Y_OUTPUT"; printf '%s' "$?")" \
    'confirmation accepts lowercase y'
assert_contains "$(<"$CONFIRM_Y_OUTPUT")" "$PROJECT" \
    'confirmation displays the physical absolute root'
assert_eq '0' "$(run_confirmation 'Y' "$CREATE_TMP/confirm-Y.out"; printf '%s' "$?")" \
    'confirmation accepts uppercase Y'
assert_eq '2' "$(run_confirmation '' "$CREATE_TMP/confirm-blank.out"; printf '%s' "$?")" \
    'blank confirmation cancels'
assert_eq '2' "$(run_confirmation 'n' "$CREATE_TMP/confirm-n.out"; printf '%s' "$?")" \
    'negative confirmation cancels'

set +e
NO_TTY_OUTPUT="$("$DISPATCHER" create-project vendor/project </dev/null 2>&1)"
NO_TTY_STATUS=$?
set -e
assert_eq '1' "$NO_TTY_STATUS" 'create-project requires confirmation without --yes'
assert_contains "$NO_TTY_OUTPUT" 'pass --yes for automation' \
    'non-interactive failure explains automation flag'

SUCCESS_PROJECT="$CREATE_TMP/success app"
SUCCESS_WARI="$SUCCESS_PROJECT/.wari"
SUCCESS_DISPATCHER="$SUCCESS_PROJECT/wari"
SUCCESS_CAPTURE="$CREATE_TMP/success-composer.capture"
make_create_project_fixture "$SUCCESS_PROJECT"
write_fake_composer "$SUCCESS_WARI/composer"

set +e
SUCCESS_OUTPUT="$(
    FAKE_COMPOSER_CAPTURE="$SUCCESS_CAPTURE" \
        "$SUCCESS_DISPATCHER" create-project --yes \
        vendor/project '^2.0' --yes --prefer-dist 2>&1
)"
SUCCESS_STATUS=$?
set -e
assert_eq '0' "$SUCCESS_STATUS" 'create-project publishes a staged Composer project'
SUCCESS_COMPOSER_CALL="$(read_file_or_empty "$SUCCESS_CAPTURE")"
assert_contains "$SUCCESS_COMPOSER_CALL" 'argc=5' \
    'create-project removes every Wari --yes argument'
assert_contains "$SUCCESS_COMPOSER_CALL" 'arg0=<create-project>' \
    'create-project selects the Composer command'
assert_contains "$SUCCESS_COMPOSER_CALL" 'arg1=<vendor/project>' \
    'create-project forwards the package'
assert_contains "$SUCCESS_COMPOSER_CALL" ".success app.wari-create." \
    'create-project injects a sibling staging directory'
assert_contains "$SUCCESS_COMPOSER_CALL" 'arg3=<^2.0>' \
    'create-project forwards the optional version'
assert_contains "$SUCCESS_COMPOSER_CALL" 'arg4=<--prefer-dist>' \
    'create-project forwards Composer options'
assert_eq '0' "$(test -f "$SUCCESS_PROJECT/composer.json"; printf '%s' "$?")" \
    'create-project publishes composer.json'
assert_eq 'hidden' "$(read_file_or_empty "$SUCCESS_PROJECT/.env")" \
    'create-project publishes top-level dotfiles'
assert_eq '<?php' "$(read_file_or_empty "$SUCCESS_PROJECT/src/App.php")" \
    'create-project publishes nested source files'
assert_eq '[core]' "$(read_file_or_empty "$SUCCESS_PROJECT/.git/config")" \
    'create-project publishes hidden directories'
assert_eq '0' "$(test -x "$SUCCESS_PROJECT/wari" && test -d "$SUCCESS_WARI"; printf '%s' "$?")" \
    'create-project preserves Wari runtime paths'
assert_contains "$SUCCESS_OUTPUT" "$SUCCESS_PROJECT" \
    'create-project success reports the physical project root'
assert_contains "$SUCCESS_OUTPUT" './wari php --version' \
    'create-project success prints a framework-neutral PHP command'
assert_eq '' "$(find "$CREATE_TMP" -maxdepth 1 -name '.success app.wari-create.*' -print -quit)" \
    'create-project removes its sibling staging directory'

IGNORE_PROJECT="$CREATE_TMP/package-ignore"
IGNORE_WARI="$IGNORE_PROJECT/.wari"
IGNORE_CAPTURE="$CREATE_TMP/package-ignore.capture"
make_create_project_fixture "$IGNORE_PROJECT"
write_fake_composer "$IGNORE_WARI/composer"
set +e
FAKE_COMPOSER_CAPTURE="$IGNORE_CAPTURE" FAKE_COMPOSER_MODE='success-gitignore' \
    "$IGNORE_PROJECT/wari" create-project --yes vendor/project >/dev/null 2>&1
IGNORE_STATUS=$?
set -e
assert_eq '0' "$IGNORE_STATUS" 'create-project merges a package gitignore'
assert_contains "$(<"$IGNORE_PROJECT/.gitignore")" '/vendor/' \
    'create-project preserves package ignore rules'
assert_contains "$(<"$IGNORE_PROJECT/.gitignore")" '/.wari/' \
    'create-project preserves Wari runtime ignore rules'
assert_eq '1' "$(awk '$0 == "# Wari local runtime" { count++ } END { print count + 0 }' \
    "$IGNORE_PROJECT/.gitignore")" 'create-project writes one Wari ignore block'

run_failure_case() {
    local label="$1"
    local mode="$2"
    local expected_status="$3"
    local project="$CREATE_TMP/$label"
    local wari="$project/.wari"
    local dispatcher="$project/wari"
    local capture="$CREATE_TMP/$label.capture"
    local output status

    make_create_project_fixture "$project"
    write_fake_composer "$wari/composer"
    set +e
    output="$(
        FAKE_COMPOSER_CAPTURE="$capture" \
        FAKE_COMPOSER_MODE="$mode" \
        FAKE_PROJECT_ROOT="$project" \
            "$dispatcher" create-project --yes vendor/project 2>&1
    )"
    status=$?
    set -e

    assert_eq "$expected_status" "$status" "$label returns the expected status"
    assert_eq '0' "$(test -x "$project/wari" && test -d "$wari"; printf '%s' "$?")" \
        "$label preserves Wari paths"
    assert_eq '' "$(find "$CREATE_TMP" -maxdepth 1 -name ".$label.wari-create.*" -print -quit)" \
        "$label removes its staging directory"
    FAILURE_OUTPUT="$output"
    FAILURE_PROJECT="$project"
}

run_failure_case 'composer-failure' fail 17
assert_eq '4' "$(find "$FAILURE_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'Composer failure leaves only Wari entries'

run_failure_case 'missing-composer-json' missing-composer-json 1
assert_contains "$FAILURE_OUTPUT" 'did not create composer.json' \
    'create-project explains a missing composer.json'
assert_eq '4' "$(find "$FAILURE_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'validation failure leaves only Wari entries'

run_failure_case 'wari-collision' wari-collision 1
assert_contains "$FAILURE_OUTPUT" 'reserved Wari paths' \
    'create-project rejects a staged wari collision'
assert_eq '4' "$(find "$FAILURE_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'wari collision cannot replace runtime entries'

run_failure_case 'runtime-collision' runtime-collision 1
assert_contains "$FAILURE_OUTPUT" 'reserved Wari paths' \
    'create-project rejects a staged .wari collision'
assert_eq '4' "$(find "$FAILURE_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'runtime collision cannot replace runtime entries'

run_failure_case 'concurrent-entry' concurrent-entry 1
assert_eq 'unrelated' "$(read_file_or_empty "$FAILURE_PROJECT/concurrent.txt")" \
    'create-project preserves an unrelated concurrent entry'
assert_eq '0' "$(test ! -e "$FAILURE_PROJECT/generated.txt"; printf '%s' "$?")" \
    'create-project publishes nothing after a concurrent root change'

ROLLBACK_PROJECT="$CREATE_TMP/publish-rollback"
ROLLBACK_WARI="$ROLLBACK_PROJECT/.wari"
ROLLBACK_DISPATCHER="$ROLLBACK_PROJECT/wari"
ROLLBACK_CAPTURE="$CREATE_TMP/publish-rollback.capture"
ROLLBACK_SHIMS="$CREATE_TMP/publish-rollback-shims"
REAL_MV="$(command -v mv)"
make_create_project_fixture "$ROLLBACK_PROJECT"
write_fake_composer "$ROLLBACK_WARI/composer"
mkdir -p "$ROLLBACK_SHIMS"
cat >"$ROLLBACK_SHIMS/mv" <<'FAKE_MV'
#!/usr/bin/env bash
set -u

source_index=$(($# - 1))
destination_index=$#
source="${!source_index}"
destination="${!destination_index}"
if [[ "${source##*/}" == src ]]; then
    mkdir -p "$destination"
    printf 'unrelated\n' >"$destination/owner.txt"
    exit 23
fi
exec "${REAL_MV:?}" "$@"
FAKE_MV
chmod 755 "$ROLLBACK_SHIMS/mv"

set +e
ROLLBACK_OUTPUT="$(
    PATH="$ROLLBACK_SHIMS:$PATH" \
    REAL_MV="$REAL_MV" \
    FAKE_COMPOSER_CAPTURE="$ROLLBACK_CAPTURE" \
        "$ROLLBACK_DISPATCHER" create-project --yes vendor/project 2>&1
)"
ROLLBACK_STATUS=$?
set -e
assert_eq '23' "$ROLLBACK_STATUS" 'publication failure preserves the failing move status'
assert_eq 'unrelated' "$(read_file_or_empty "$ROLLBACK_PROJECT/src/owner.txt")" \
    'publication rollback preserves a concurrently created destination'
assert_eq '0' "$(
    test ! -e "$ROLLBACK_PROJECT/composer.json" &&
        test ! -e "$ROLLBACK_PROJECT/generated.txt" &&
        test ! -e "$ROLLBACK_PROJECT/.env"
    printf '%s' "$?"
)" 'publication rollback removes previously published entries'
assert_eq '0' "$(test -x "$ROLLBACK_PROJECT/wari" && test -d "$ROLLBACK_WARI"; printf '%s' "$?")" \
    'publication rollback preserves Wari paths'
assert_eq '' "$(find "$CREATE_TMP" -maxdepth 1 -name '.publish-rollback.wari-create.*' -print -quit)" \
    'publication rollback removes staging'

SIGNAL_PROJECT="$CREATE_TMP/signal-cleanup"
SIGNAL_WARI="$SIGNAL_PROJECT/.wari"
SIGNAL_DISPATCHER="$SIGNAL_PROJECT/wari"
SIGNAL_CAPTURE="$CREATE_TMP/signal-composer.capture"
SIGNAL_BLOCK_CAPTURE="$CREATE_TMP/signal-block.capture"
SIGNAL_OUTPUT="$CREATE_TMP/signal.out"
make_create_project_fixture "$SIGNAL_PROJECT"
write_fake_composer "$SIGNAL_WARI/composer"
FAKE_COMPOSER_CAPTURE="$SIGNAL_CAPTURE" \
FAKE_COMPOSER_MODE=block \
FAKE_BLOCK_CAPTURE="$SIGNAL_BLOCK_CAPTURE" \
    "$SIGNAL_DISPATCHER" create-project --yes vendor/project \
    >"$SIGNAL_OUTPUT" 2>&1 &
SIGNAL_COMMAND_PID=$!

SIGNAL_ATTEMPT=0
while [[ ! -s "$SIGNAL_BLOCK_CAPTURE" && "$SIGNAL_ATTEMPT" -lt 500 ]]; do
    sleep 0.02
    SIGNAL_ATTEMPT=$((SIGNAL_ATTEMPT + 1))
done
assert_eq '0' "$(test -s "$SIGNAL_BLOCK_CAPTURE"; printf '%s' "$?")" \
    'signal fixture reaches the Composer subprocess'
SIGNAL_STAGING="$(sed -n '1p' "$SIGNAL_BLOCK_CAPTURE")"
SIGNAL_COMPOSER_PID="$(sed -n '2p' "$SIGNAL_BLOCK_CAPTURE")"
kill -TERM "$SIGNAL_COMMAND_PID" "$SIGNAL_COMPOSER_PID" >/dev/null 2>&1 || true
set +e
wait "$SIGNAL_COMMAND_PID"
SIGNAL_STATUS=$?
set -e
assert_eq '143' "$SIGNAL_STATUS" 'TERM returns the conventional signal status'
assert_eq '0' "$(test ! -e "$SIGNAL_STAGING"; printf '%s' "$?")" \
    'TERM removes the active staging directory'
assert_eq '4' "$(find "$SIGNAL_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'TERM leaves only Wari entries'

INT_PROJECT="$CREATE_TMP/int-cleanup"
INT_WARI="$INT_PROJECT/.wari"
INT_DISPATCHER="$INT_PROJECT/wari"
INT_CAPTURE="$CREATE_TMP/int-composer.capture"
INT_BLOCK_CAPTURE="$CREATE_TMP/int-block.capture"
INT_COMMAND_PID_CAPTURE="$CREATE_TMP/int-command-pid.capture"
make_create_project_fixture "$INT_PROJECT"
write_fake_composer "$INT_WARI/composer"

(
    attempt=0
    while { [[ ! -s "$INT_COMMAND_PID_CAPTURE" ]] ||
        [[ ! -s "$INT_BLOCK_CAPTURE" ]]; } && ((attempt < 500)); do
        sleep 0.02
        attempt=$((attempt + 1))
    done
    command_pid="$(sed -n '1p' "$INT_COMMAND_PID_CAPTURE")"
    composer_pid="$(sed -n '2p' "$INT_BLOCK_CAPTURE")"
    kill -INT "$command_pid" "$composer_pid"
) &
INT_KILLER_PID=$!

set +e
FAKE_COMPOSER_CAPTURE="$INT_CAPTURE" \
FAKE_COMPOSER_MODE=block \
FAKE_BLOCK_CAPTURE="$INT_BLOCK_CAPTURE" \
INT_COMMAND_PID_CAPTURE="$INT_COMMAND_PID_CAPTURE" \
    bash -c 'printf "%s\n" "$$" >"$INT_COMMAND_PID_CAPTURE"; exec "$@"' \
    bash "$INT_DISPATCHER" create-project --yes vendor/project \
    >"$CREATE_TMP/int.out" 2>&1
INT_STATUS=$?
wait "$INT_KILLER_PID"
set -e
assert_eq '130' "$INT_STATUS" 'INT returns the conventional signal status'
assert_eq '0' "$(test -s "$INT_BLOCK_CAPTURE"; printf '%s' "$?")" \
    'interrupt fixture reaches the Composer subprocess'
INT_STAGING="$(sed -n '1p' "$INT_BLOCK_CAPTURE")"
assert_eq '0' "$(test ! -e "$INT_STAGING"; printf '%s' "$?")" \
    'INT removes the active staging directory'
assert_eq '4' "$(find "$INT_PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'INT leaves only Wari entries'

finish_tests
