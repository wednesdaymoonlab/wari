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
    mkdir -p "$directory"
    cp "$CORE_DIR/wari" "$directory/wari"
    chmod 755 "$directory/wari"
    local launcher_sha
    launcher_sha="$(calculate_checksum sha256 "$directory/wari")"
    sed "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
        "$CORE_DIR/wari.lock" >"$directory/wari.lock"
}

write_candidate_lock() {
    local launcher="$1"
    local output="$2"
    local frankenphp_request="$3"
    local composer_request="$4"
    local linux_build="$5"
    local launcher_sha
    local frankenphp_version="${frankenphp_request:-1.13.0}"
    local composer_version="${composer_request:-2.10.3}"

    launcher_sha="$(calculate_checksum sha256 "$launcher")"
    sed \
        -e "s/^frankenphp_version=.*/frankenphp_version=$frankenphp_version/" \
        -e "s/^composer_version=.*/composer_version=$composer_version/" \
        -e "s/^linux_build=.*/linux_build=$linux_build/" \
        -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
        "$CORE_DIR/wari.lock" >"$output"
}

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
assert_eq $'1.13.0\t\tstatic' "$(<"$UPDATE_TMP/update-arguments")" \
    'dependency update forwards one exact version and preserves Linux build'
assert_eq 'local runtime' "$(<"$PROJECT/.wari/marker")" \
    'dependency update leaves the local runtime untouched'
assert_contains "$UPDATE_OUTPUT" './wari setup' \
    'dependency update keeps runtime replacement explicit'

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
make_pair "$NOOP_PROJECT"
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

MODIFIED_PROJECT="$UPDATE_TMP/modified"
make_pair "$MODIFIED_PROJECT"
printf '# local edit\n' >>"$MODIFIED_PROJECT/wari"
NETWORK_MARKER="$UPDATE_TMP/network-called"
generate_update_lock() { : >"$NETWORK_MARKER"; return 1; }
assert_fails 'dependency update refuses a locally modified launcher' \
    env WARI_PROJECT_ROOT="$MODIFIED_PROJECT" \
    WARI_LAUNCHER="$MODIFIED_PROJECT/wari" bash -c \
    'source "$1/wari"; update_main --yes' _ "$MODIFIED_PROJECT"
assert_eq '0' "$(test ! -e "$NETWORK_MARKER"; printf '%s' "$?")" \
    'modified launcher is rejected before metadata resolution'

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
    local launcher="$1" output="$2"
    local launcher_sha
    launcher_sha="$(calculate_checksum sha256 "$launcher")"
    sed \
        -e 's/^wari_version=.*/wari_version=0.3.0/' \
        -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
        "$CORE_DIR/wari.lock" >"$output"
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
fi
assert_eq 'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari' \
    "$(<"$UPDATE_TMP/self-url")" \
    'self-update downloads only the exact semantic-version tag'
assert_eq 'self runtime' "$(<"$SELF_PROJECT/.wari/marker")" \
    'self-update leaves the local runtime untouched'
assert_contains "$SELF_OUTPUT" './wari setup' \
    'self-update keeps runtime refresh explicit'
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
        local launcher_sha
        launcher_sha="$(calculate_checksum sha256 "$1")"
        sed -e 's/^wari_version=.*/wari_version=0.3.0/' \
            -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
            "$CORE_DIR/wari.lock" >"$2"
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
        local launcher_sha
        launcher_sha="$(calculate_checksum sha256 "$1")"
        sed -e 's/^wari_version=.*/wari_version=0.3.0/' \
            -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
            "$CORE_DIR/wari.lock" >"$2"
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
        local launcher_sha
        launcher_sha="$(calculate_checksum sha256 "$1")"
        sed -e 's/^wari_version=.*/wari_version=0.3.0/' \
            -e "s/^wari_sha256=.*/wari_sha256=$launcher_sha/" \
            "$CORE_DIR/wari.lock" >"$2"
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
