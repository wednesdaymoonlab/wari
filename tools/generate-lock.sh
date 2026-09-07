#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    printf '%s\n' \
        'Usage: generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>' \
        '' \
        'Generate a canonical wari.lock from exact official release metadata.'
}

die() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

validate_semver() {
    [[ "${1-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        die "invalid semantic version: ${1-}"
        return 1
    }
}

main() (
    local requested_wari_version="${1-}"
    local frankenphp_version="${2-}"
    local composer_version="${3-}"
    local linux_build="${4-}"
    local script_dir core_dir actual_wari_version temporary

    if [[ "${1-}" == --help || "${1-}" == -h ]]; then
        usage
        return 0
    fi
    [[ "$#" -eq 4 ]] || { usage >&2; return 2; }
    validate_semver "$requested_wari_version" || return 2
    validate_semver "$frankenphp_version" || return 2
    validate_semver "$composer_version" || return 2
    [[ "$linux_build" == static || "$linux_build" == gnu ]] || {
        die "invalid Linux build: $linux_build"
        return 2
    }

    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    core_dir="$(dirname -- "$script_dir")"
    [[ -f "$core_dir/wari" && ! -L "$core_dir/wari" ]] || {
        die "local Wari launcher is invalid: $core_dir/wari"
        return 1
    }
    actual_wari_version="$(bash "$core_dir/wari" --version-value)" || return 1
    [[ "$actual_wari_version" == "$requested_wari_version" ]] || {
        die "requested Wari version does not match local launcher: $actual_wari_version"
        return 1
    }

    temporary="$(mktemp -d "${TMPDIR:-/tmp}/wari-lock-generate.XXXXXX")" || return $?
    cleanup_generator_wrapper() {
        local status=$?
        case "$temporary" in
            "${TMPDIR:-/tmp}"/wari-lock-generate.?*) rm -rf -- "$temporary" ;;
        esac
        exit "$status"
    }
    trap cleanup_generator_wrapper EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    bash "$core_dir/wari" --generate-lock "$temporary/wari.lock" \
        --frankenphp "$frankenphp_version" \
        --composer "$composer_version" \
        --linux-build "$linux_build" || return 1
    command cat "$temporary/wari.lock"
)

main "$@"
