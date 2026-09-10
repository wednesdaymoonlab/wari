#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"

UPDATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-update-test.XXXXXX")"
UPDATE_TMP="$(CDPATH= cd -- "$UPDATE_TMP" && pwd -P)"
trap 'rm -rf -- "$UPDATE_TMP"' EXIT

make_pair() {
    local directory="$1"
    local lock_version="${2:-1}"
    mkdir -p "$directory"
    cp "$CORE_DIR/wari" "$directory/wari"
    chmod 755 "$directory/wari"
    if [[ "$lock_version" == '2' ]]; then
        write_format2_lock "$directory/wari.lock"
    else
        write_format1_lock "$directory/wari.lock" "$directory/wari"
    fi
}

write_candidate_lock() {
    local launcher="$1"
    local output="$2"
    local frankenphp_request="$3"
    local composer_request="$4"
    local linux_build="$5"
    local frankenphp_version="${frankenphp_request:-1.13.0}"
    local composer_version="${composer_request:-2.10.3}"
    local wari_version

    wari_version="$(bash "$launcher" --version-value)" || return 1
    write_format2_lock "$output" "$wari_version" "$frankenphp_version" \
        "$composer_version" "$linux_build"
}

GENERATOR_LAUNCHER="$UPDATE_TMP/generator-launcher"
GENERATOR_ARGUMENTS="$UPDATE_TMP/generator-arguments"
cat >"$GENERATOR_LAUNCHER" <<'GENERATOR_FIXTURE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >"$WARI_GENERATOR_ARGUMENTS"
output="$2"
printf '%s\n' \
    'lock_version=2' \
    'wari_version=0.4.2' \
    'frankenphp_version=1.12.7' \
    'composer_version=2.8.11' \
    'linux_build=static' >"$output"
GENERATOR_FIXTURE
chmod 755 "$GENERATOR_LAUNCHER"
WARI_GENERATOR_ARGUMENTS="$GENERATOR_ARGUMENTS" \
    generate_update_lock "$GENERATOR_LAUNCHER" \
    "$UPDATE_TMP/generated-update.lock" 1.12.7 2.8.11 static
assert_contains "$(<"$GENERATOR_ARGUMENTS")" $'--lock-version\n2' \
    'dependency update explicitly requests lock format 2'
WARI_GENERATOR_ARGUMENTS="$GENERATOR_ARGUMENTS" \
    generate_self_update_lock "$GENERATOR_LAUNCHER" \
    "$UPDATE_TMP/generated-self-update.lock" 1.12.7 2.8.11 static
assert_contains "$(<"$GENERATOR_ARGUMENTS")" $'--lock-version\n2' \
    'self-update explicitly requests lock format 2'

PROJECT="$UPDATE_TMP/project"
make_pair "$PROJECT"
mkdir "$PROJECT/.wari"
printf 'local runtime\n' >"$PROJECT/.wari/marker"
LAUNCHER_BEFORE="$(calculate_checksum sha256 "$PROJECT/wari")"

generate_update_lock() {
    printf '%s\t%s\t%s\n' "$3" "$4" "$5" >"$UPDATE_TMP/update-arguments"
    write_candidate_lock "$1" "$2" "$3" "$4" "$5"
}

set +e
UPDATE_OUTPUT="$(WARI_PROJECT_ROOT="$PROJECT" WARI_LAUNCHER="$PROJECT/wari" \
    update_main --yes --frankenphp 1.13.0 2>&1)"
UPDATE_STATUS=$?
set -e
assert_eq '0' "$UPDATE_STATUS" 'dependency update publishes a generated lock'
assert_eq "$LAUNCHER_BEFORE" "$(calculate_checksum sha256 "$PROJECT/wari")" \
    'dependency update never changes the launcher'
assert_contains "$(<"$PROJECT/wari.lock")" 'frankenphp_version=1.13.0' \
    'dependency update publishes the exact FrankenPHP selection'
assert_contains "$(<"$PROJECT/wari.lock")" 'composer_version=2.10.3' \
    'an omitted Composer version resolves latest stable'
assert_eq 'lock_version=2' "$(sed -n '1p' "$PROJECT/wari.lock")" \
    'dependency update migrates a format 1 project lock to format 2'
assert_not_contains "$(<"$PROJECT/wari.lock")" '_sha' \
    'migrated dependency lock contains no checksum keys'
assert_eq $'1.13.0\t\tstatic' "$(<"$UPDATE_TMP/update-arguments")" \
    'dependency update forwards one exact version and preserves Linux build'
assert_eq 'local runtime' "$(<"$PROJECT/.wari/marker")" \
    'dependency update leaves the local runtime untouched'
assert_contains "$UPDATE_OUTPUT" './wari setup' \
    'dependency update keeps runtime replacement explicit'
assert_contains "$UPDATE_OUTPUT" '+ WARI DEPENDENCY UPDATE' \
    'dependency update starts with a retro header'
assert_contains "$UPDATE_OUTPUT" '[ OK ] FrankenPHP' \
    'dependency update reports the selected FrankenPHP transition'
assert_contains "$UPDATE_OUTPUT" '+ UPDATED' \
    'dependency update separates its completion state'

GNU_PROJECT="$UPDATE_TMP/gnu-project"
make_pair "$GNU_PROJECT"
generate_update_lock() {
    printf '%s\t%s\t%s\n' "$3" "$4" "$5" >"$UPDATE_TMP/gnu-arguments"
    write_candidate_lock "$1" "$2" "$3" "$4" "$5"
}
WARI_PROJECT_ROOT="$GNU_PROJECT" WARI_LAUNCHER="$GNU_PROJECT/wari" \
    update_main --yes --composer 2.9.0 --linux-build gnu >/dev/null
assert_eq $'\t2.9.0\tgnu' "$(<"$UPDATE_TMP/gnu-arguments")" \
    'dependency update forwards Composer and explicit GNU override'

NOOP_PROJECT="$UPDATE_TMP/noop"
make_pair "$NOOP_PROJECT" 2
NOOP_INODE_BEFORE="$(ls -di "$NOOP_PROJECT/wari.lock" | awk '{print $1}')"
generate_update_lock() { cp "$NOOP_PROJECT/wari.lock" "$2"; }
WARI_PROJECT_ROOT="$NOOP_PROJECT" WARI_LAUNCHER="$NOOP_PROJECT/wari" \
    update_main --yes >/dev/null
assert_eq "$NOOP_INODE_BEFORE" \
    "$(ls -di "$NOOP_PROJECT/wari.lock" | awk '{print $1}')" \
    'an unchanged dependency lock is not rewritten'

DECLINE_PROJECT="$UPDATE_TMP/decline"
make_pair "$DECLINE_PROJECT"
DECLINE_BEFORE="$(calculate_checksum sha256 "$DECLINE_PROJECT/wari.lock")"
set +e
(
    WARI_PROJECT_ROOT="$DECLINE_PROJECT"
    WARI_LAUNCHER="$DECLINE_PROJECT/wari"
    generate_update_lock() { write_candidate_lock "$1" "$2" '' '' static; }
    confirm_tracked_change() { return 1; }
    update_main
) >/dev/null 2>&1
DECLINE_STATUS=$?
set -e
assert_eq '0' "$DECLINE_STATUS" 'declining dependency update is a successful no-op'
assert_eq "$DECLINE_BEFORE" "$(calculate_checksum sha256 "$DECLINE_PROJECT/wari.lock")" \
    'declining dependency update preserves the lock'

MODIFIED_PROJECT="$UPDATE_TMP/version-mismatch"
make_pair "$MODIFIED_PROJECT"
sed "s/^WARI_VERSION='[^']*'/WARI_VERSION='9.9.9'/" \
    "$CORE_DIR/wari" >"$MODIFIED_PROJECT/wari"
chmod 755 "$MODIFIED_PROJECT/wari"
NETWORK_MARKER="$UPDATE_TMP/network-called"
generate_update_lock() { : >"$NETWORK_MARKER"; return 1; }
assert_fails 'dependency update refuses a mismatched launcher version' \
    env WARI_PROJECT_ROOT="$MODIFIED_PROJECT" \
    WARI_LAUNCHER="$MODIFIED_PROJECT/wari" bash -c \
    'source "$1/wari"; update_main --yes' _ "$MODIFIED_PROJECT"
assert_eq '0' "$(test ! -e "$NETWORK_MARKER"; printf '%s' "$?")" \
    'mismatched launcher version is rejected before metadata resolution'

assert_fails 'dependency update rejects a missing FrankenPHP value' \
    update_main --frankenphp
assert_fails 'dependency update rejects an unknown option' \
    update_main --channel preview

SELF_PROJECT="$UPDATE_TMP/self-project"
SELF_CANDIDATE="$UPDATE_TMP/self-candidate"
make_pair "$SELF_PROJECT"
sed "s/^WARI_VERSION='[^']*'/WARI_VERSION='0.3.0'/" \
    "$CORE_DIR/wari" >"$SELF_CANDIDATE"
chmod 755 "$SELF_CANDIDATE"
mkdir "$SELF_PROJECT/.wari"
printf 'self runtime\n' >"$SELF_PROJECT/.wari/marker"

download_file() {
    printf '%s\n' "$1" >"$UPDATE_TMP/self-url"
    cp "$SELF_CANDIDATE" "$2"
}
generate_self_update_lock() {
    write_format2_lock "$2" 0.3.0 1.12.7 2.8.11 static
}
set +e
SELF_OUTPUT="$(WARI_PROJECT_ROOT="$SELF_PROJECT" \
    WARI_LAUNCHER="$SELF_PROJECT/wari" self_update_main 0.3.0 --yes 2>&1)"
SELF_STATUS=$?
set -e
assert_eq '0' "$SELF_STATUS" 'self-update publishes an exact tagged launcher pair'
if [[ "$SELF_STATUS" -eq 0 ]]; then
    assert_eq 'Wari 0.3.0' "$("$SELF_PROJECT/wari" --version)" \
        'self-update publishes the requested launcher version'
    assert_contains "$(<"$SELF_PROJECT/wari.lock")" 'wari_version=0.3.0' \
        'self-update binds the lock to the new launcher'
    assert_contains "$(<"$SELF_PROJECT/wari.lock")" 'frankenphp_version=1.12.7' \
        'self-update preserves the exact FrankenPHP selection'
    assert_contains "$(<"$SELF_PROJECT/wari.lock")" 'composer_version=2.8.11' \
        'self-update preserves the exact Composer selection'
    assert_eq 'lock_version=2' "$(sed -n '1p' "$SELF_PROJECT/wari.lock")" \
        'self-update publishes the current project lock format'
    assert_not_contains "$(<"$SELF_PROJECT/wari.lock")" '_sha' \
        'self-update lock contains no checksum keys'
fi
assert_eq 'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
    "$(<"$UPDATE_TMP/self-url")" \
    'self-update downloads only the exact semantic-version tag'
assert_eq 'self runtime' "$(<"$SELF_PROJECT/.wari/marker")" \
    'self-update leaves the local runtime untouched'
assert_contains "$SELF_OUTPUT" './wari setup' \
    'self-update keeps runtime refresh explicit'
assert_contains "$SELF_OUTPUT" '+ WARI SELF-UPDATE' \
    'self-update starts with a retro header'
assert_contains "$SELF_OUTPUT" '[ OK ] Wari' \
    'self-update reports the selected Wari transition'
assert_contains "$SELF_OUTPUT" '+ UPDATED' \
    'self-update separates its completion state'
assert_fails 'self-update requires an exact target version' self_update_main
assert_fails 'self-update rejects prerelease target text' \
    self_update_main 0.3.0-rc1 --yes
assert_eq '0' "$(self_update_main --help >/dev/null 2>&1; printf '%s' "$?")" \
    'self-update help works without a target version'

UPDATE_SIGNAL_PROJECT="$UPDATE_TMP/update-signal-project"
make_pair "$UPDATE_SIGNAL_PROJECT"
set +e
(
    WARI_PROJECT_ROOT="$UPDATE_SIGNAL_PROJECT"
    WARI_LAUNCHER="$UPDATE_SIGNAL_PROJECT/wari"
    generate_update_lock() { write_candidate_lock "$1" "$2" '1.13.0' '' static; }
    mv() {
        local source destination
        if [[ "${1-}" == -- ]]; then shift; fi
        source="$1"; destination="$2"
        command mv "$source" "$destination" || return $?
        if [[ "$destination" == "$UPDATE_SIGNAL_PROJECT/wari.lock" ]]; then
            sh -c 'kill -TERM "$PPID"'
        fi
    }
    update_main --yes
) >/dev/null 2>&1
UPDATE_SIGNAL_STATUS=$?
set -e
assert_eq '0' "$UPDATE_SIGNAL_STATUS" \
    'dependency update masks TERM across lock publication bookkeeping'
assert_contains "$(<"$UPDATE_SIGNAL_PROJECT/wari.lock")" 'frankenphp_version=1.13.0' \
    'signal-safe dependency update keeps the newly selected lock'

UPDATE_RECOVERY_PROJECT="$UPDATE_TMP/update-recovery-project"
make_pair "$UPDATE_RECOVERY_PROJECT"
set +e
UPDATE_RECOVERY_OUTPUT="$( (
    WARI_PROJECT_ROOT="$UPDATE_RECOVERY_PROJECT"
    WARI_LAUNCHER="$UPDATE_RECOVERY_PROJECT/wari"
    generate_update_lock() { write_candidate_lock "$1" "$2" '1.13.0' '' static; }
    eval "$(declare -f validate_launcher_pair | \
        sed '1s/validate_launcher_pair/original_validate_launcher_pair/')"
    validate_calls=0
    validate_launcher_pair() {
        validate_calls=$((validate_calls + 1))
        original_validate_launcher_pair "$@" || return $?
        [[ "$validate_calls" -lt 3 ]]
    }
    cp() {
        if [[ "${1-}" == */wari.lock.old &&
            "${2-}" == "$UPDATE_RECOVERY_PROJECT/wari.lock" ]]; then
            return 75
        fi
        command cp "$@"
    }
    update_main --yes
) 2>&1)"
UPDATE_RECOVERY_STATUS=$?
set -e
assert_eq '0' "$(test "$UPDATE_RECOVERY_STATUS" -ne 0; printf '%s' "$?")" \
    'dependency update reports post-publication validation failure'
assert_contains "$UPDATE_RECOVERY_OUTPUT" 'rollback failed; recovery files remain in' \
    'dependency update reports the retained recovery directory'
assert_eq '1' "$(find "$UPDATE_RECOVERY_PROJECT" -maxdepth 1 -type d \
    -name '.wari-update.*' | wc -l | tr -d ' ')" \
    'dependency update retains its old lock when rollback fails'

ROLLBACK_PROJECT="$UPDATE_TMP/rollback-project"
make_pair "$ROLLBACK_PROJECT"
ROLLBACK_LAUNCHER_BEFORE="$(calculate_checksum sha256 "$ROLLBACK_PROJECT/wari")"
ROLLBACK_LOCK_BEFORE="$(calculate_checksum sha256 "$ROLLBACK_PROJECT/wari.lock")"
set +e
(
    WARI_PROJECT_ROOT="$ROLLBACK_PROJECT"
    WARI_LAUNCHER="$ROLLBACK_PROJECT/wari"
    download_file() { cp "$SELF_CANDIDATE" "$2"; }
    generate_self_update_lock() {
        write_format2_lock "$2" 0.3.0 1.12.7 2.8.11 static
    }
    mv() {
        local source destination
        if [[ "${1-}" == -- ]]; then shift; fi
        source="${1-}"; destination="${2-}"
        if [[ "$source" == */wari.lock &&
            "$destination" == "$ROLLBACK_PROJECT/wari.lock" ]]; then
            return 73
        fi
        command mv "$source" "$destination"
    }
    self_update_main 0.3.0 --yes
) >/dev/null 2>&1
ROLLBACK_STATUS=$?
set -e
assert_eq '0' "$(test "$ROLLBACK_STATUS" -ne 0; printf '%s' "$?")" \
    'self-update reports a second-file publication failure'
assert_eq "$ROLLBACK_LAUNCHER_BEFORE" \
    "$(calculate_checksum sha256 "$ROLLBACK_PROJECT/wari")" \
    'self-update restores the old launcher after partial publication'
assert_eq "$ROLLBACK_LOCK_BEFORE" \
    "$(calculate_checksum sha256 "$ROLLBACK_PROJECT/wari.lock")" \
    'self-update preserves the old lock after partial publication'

CHMOD_PROJECT="$UPDATE_TMP/chmod-project"
make_pair "$CHMOD_PROJECT"
CHMOD_LAUNCHER_BEFORE="$(calculate_checksum sha256 "$CHMOD_PROJECT/wari")"
set +e
(
    WARI_PROJECT_ROOT="$CHMOD_PROJECT"
    WARI_LAUNCHER="$CHMOD_PROJECT/wari"
    download_file() { cp "$SELF_CANDIDATE" "$2"; }
    generate_self_update_lock() {
        write_format2_lock "$2" 0.3.0 1.12.7 2.8.11 static
    }
    chmod() {
        if [[ "${2-}" == "$CHMOD_PROJECT/wari" ]]; then return 74; fi
        command chmod "$@"
    }
    self_update_main 0.3.0 --yes
) >/dev/null 2>&1
CHMOD_STATUS=$?
set -e
assert_eq '0' "$(test "$CHMOD_STATUS" -ne 0; printf '%s' "$?")" \
    'self-update reports a public launcher chmod failure'
assert_eq "$CHMOD_LAUNCHER_BEFORE" \
    "$(calculate_checksum sha256 "$CHMOD_PROJECT/wari")" \
    'self-update restores the old launcher after chmod failure'

SIGNAL_PROJECT="$UPDATE_TMP/signal-project"
make_pair "$SIGNAL_PROJECT"
set +e
(
    WARI_PROJECT_ROOT="$SIGNAL_PROJECT"
    WARI_LAUNCHER="$SIGNAL_PROJECT/wari"
    download_file() { cp "$SELF_CANDIDATE" "$2"; }
    generate_self_update_lock() {
        write_format2_lock "$2" 0.3.0 1.12.7 2.8.11 static
    }
    mv() {
        local source destination
        if [[ "${1-}" == -- ]]; then shift; fi
        source="$1"; destination="$2"
        command mv "$source" "$destination" || return $?
        if [[ "$destination" == "$SIGNAL_PROJECT/wari" ]]; then
            sh -c 'kill -TERM "$PPID"'
        fi
    }
    self_update_main 0.3.0 --yes
) >/dev/null 2>&1
SIGNAL_STATUS=$?
set -e
assert_eq '0' "$SIGNAL_STATUS" \
    'self-update masks TERM across launcher publication bookkeeping'
if [[ "$SIGNAL_STATUS" -eq 0 ]]; then
    assert_eq 'Wari 0.3.0' "$("$SIGNAL_PROJECT/wari" --version)" \
        'signal-safe self-update completes the selected launcher pair'
    bash "$SIGNAL_PROJECT/wari" --validate-pair "$SIGNAL_PROJECT/wari.lock"
    assert_eq '0' "$?" 'signal-safe self-update publishes a valid pair'
fi

finish_tests
