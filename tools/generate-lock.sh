#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    printf '%s\n' \
        'Usage: generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>' \
        '' \
        'Generate a canonical wari.lock from exact official release artifacts.'
}

die() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

calculate_checksum() {
    local algorithm="$1"
    local file="$2"
    local output

    case "$algorithm" in
        sha256)
            if command -v sha256sum >/dev/null 2>&1; then
                output="$(sha256sum "$file")"
            elif command -v shasum >/dev/null 2>&1; then
                output="$(shasum -a 256 "$file")"
            else
                die 'no SHA-256 checksum utility found'
                return 1
            fi
            ;;
        sha384)
            if command -v sha384sum >/dev/null 2>&1; then
                output="$(sha384sum "$file")"
            elif command -v shasum >/dev/null 2>&1; then
                output="$(shasum -a 384 "$file")"
            else
                die 'no SHA-384 checksum utility found'
                return 1
            fi
            ;;
        *) die "unsupported checksum algorithm: $algorithm"; return 1 ;;
    esac

    output="${output%%[[:space:]]*}"
    printf '%s\n' "$output" | tr 'A-F' 'a-f'
}

curl_to_file() {
    local url="$1"
    local destination="$2"
    shift 2
    local attempt=1
    local max_attempts=4
    local status

    while ((attempt <= max_attempts)); do
        if curl --fail --show-error --silent --location --connect-timeout 15 \
            "$@" "$url" --output "$destination"; then
            return 0
        else
            status=$?
        fi
        if ((attempt == max_attempts)); then
            die "download failed after $max_attempts attempts (curl exit $status): $url"
            return "$status"
        fi
        printf 'Download failed (attempt %s/%s); retrying...\n' \
            "$attempt" "$max_attempts" >&2
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

release_asset_checksum() {
    local json_file="$1"
    local asset_name="$2"
    local record
    local digest
    local url
    local expected_url

    record="$(awk -v target="$asset_name" '
        function json_string(line, value) {
            value = line
            sub(/^[^:]*:[[:space:]]*"/, "", value)
            sub(/"[,]*[[:space:]]*$/, "", value)
            return value
        }
        /^[[:space:]]*"name":[[:space:]]*"/ {
            value = json_string($0)
            if (value == target) { matches++; active = 1 } else { active = 0 }
            next
        }
        active && /^[[:space:]]*"digest":[[:space:]]*"/ {
            digest = json_string($0)
            next
        }
        active && /^[[:space:]]*"browser_download_url":[[:space:]]*"/ {
            url = json_string($0)
            active = 0
        }
        END {
            if (matches != 1 || digest == "" || url == "") exit 2
            printf "%s\t%s\n", digest, url
        }
    ' "$json_file")" || {
        die "release metadata has no unique complete asset named $asset_name"
        return 1
    }

    IFS=$'\t' read -r digest url <<<"$record"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        die "invalid digest for FrankenPHP asset: $asset_name"
        return 1
    }
    expected_url="https://github.com/php/frankenphp/releases/download/v$FRANKENPHP_VERSION/$asset_name"
    [[ "$url" == "$expected_url" ]] || {
        die "unexpected FrankenPHP asset URL: $url"
        return 1
    }
    printf '%s\n' "${digest#sha256:}"
}

cleanup() {
    local status=$?
    case "${LOCK_TMP:-}" in
        "${TMPDIR:-/tmp}"/wari-lock-generate.*) rm -rf -- "$LOCK_TMP" ;;
        '') ;;
        *) printf 'Refusing to clean unsafe path: %s\n' "$LOCK_TMP" >&2 ;;
    esac
    exit "$status"
}

main() {
    if [[ "${1-}" == '--help' || "${1-}" == '-h' ]]; then
        usage
        return 0
    fi
    if [[ "$#" -ne 4 ]]; then
        usage >&2
        return 2
    fi

    WARI_RELEASE_VERSION="$1"
    FRANKENPHP_VERSION="$2"
    COMPOSER_VERSION="$3"
    LINUX_BUILD="$4"
    if [[ ! "$WARI_RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
        ! "$FRANKENPHP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
        ! "$COMPOSER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die 'versions must use exact major.minor.patch form'
        return 2
    fi
    if [[ "$LINUX_BUILD" != 'static' && "$LINUX_BUILD" != 'gnu' ]]; then
        die 'Linux build must be static or gnu'
        return 2
    fi

    local tool_dir
    local core_dir
    local release_json
    local linux_x86_asset='frankenphp-linux-x86_64'
    local linux_arm_asset='frankenphp-linux-aarch64'
    local wari_sha256
    local composer_installer_sha384
    local composer_sha256
    local linux_x86_sha256
    local linux_arm_sha256
    local mac_x86_sha256
    local mac_arm_sha256

    tool_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    core_dir="$(dirname -- "$tool_dir")"
    [[ -f "$core_dir/wari" ]] || { die 'tracked wari launcher is missing'; return 1; }
    [[ "$LINUX_BUILD" == 'static' ]] || {
        linux_x86_asset="$linux_x86_asset-gnu"
        linux_arm_asset="$linux_arm_asset-gnu"
    }

    LOCK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-lock-generate.XXXXXX")"
    trap cleanup EXIT INT TERM HUP
    release_json="$LOCK_TMP/frankenphp-release.json"
    curl_to_file \
        "https://api.github.com/repos/php/frankenphp/releases/tags/v$FRANKENPHP_VERSION" \
        "$release_json" \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28'
    curl_to_file 'https://getcomposer.org/installer' \
        "$LOCK_TMP/composer-installer.php"
    curl_to_file \
        "https://getcomposer.org/download/$COMPOSER_VERSION/composer.phar" \
        "$LOCK_TMP/composer.phar"

    wari_sha256="$(calculate_checksum sha256 "$core_dir/wari")"
    composer_installer_sha384="$(calculate_checksum sha384 "$LOCK_TMP/composer-installer.php")"
    composer_sha256="$(calculate_checksum sha256 "$LOCK_TMP/composer.phar")"
    linux_x86_sha256="$(release_asset_checksum "$release_json" "$linux_x86_asset")"
    linux_arm_sha256="$(release_asset_checksum "$release_json" "$linux_arm_asset")"
    mac_x86_sha256="$(release_asset_checksum "$release_json" 'frankenphp-mac-x86_64')"
    mac_arm_sha256="$(release_asset_checksum "$release_json" 'frankenphp-mac-arm64')"

    printf '%s\n' \
        'lock_version=1' \
        "wari_version=$WARI_RELEASE_VERSION" \
        "frankenphp_version=$FRANKENPHP_VERSION" \
        "composer_version=$COMPOSER_VERSION" \
        "linux_build=$LINUX_BUILD" \
        "wari_sha256=$wari_sha256" \
        "composer_installer_sha384=$composer_installer_sha384" \
        "composer_sha256=$composer_sha256" \
        "frankenphp_linux_x86_64_sha256=$linux_x86_sha256" \
        "frankenphp_linux_arm64_sha256=$linux_arm_sha256" \
        "frankenphp_macos_x86_64_sha256=$mac_x86_sha256" \
        "frankenphp_macos_arm64_sha256=$mac_arm_sha256"
}

main "$@"
