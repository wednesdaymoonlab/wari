#!/usr/bin/env bash

set -Eeuo pipefail

WARI_VERSION='0.1.0'
ASSUME_YES=0
REQUESTED_VERSION='latest'
LINUX_BUILD='static'
SHOW_HELP=0
VERSION_OPTION_SET=0
LINUX_BUILD_OPTION_SET=0
PLATFORM_OS=''
PLATFORM_ARCH=''
ASSET_NAME=''
RESOLVED_TAG=''
ASSET_URL=''
ASSET_SHA256=''
PROJECT_ROOT=''
STAGING_DIR=''
PUBLISHED_RUNTIME=0
PUBLISHED_DISPATCHER=0
INSTALLED_PHP_VERSION=''
INSTALLED_FRANKENPHP_VERSION=''
INSTALLED_COMPOSER_VERSION=''

FRANKENPHP_API_BASE='https://api.github.com/repos/php/frankenphp/releases'

die() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

normalize_version() {
    local version="${1-}"

    if [[ ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "invalid FrankenPHP version: $version"
        return 1
    fi

    case "$version" in
        v*) printf '%s\n' "$version" ;;
        *) printf 'v%s\n' "$version" ;;
    esac
}

usage() {
    printf '%s\n' \
        'Usage: install.sh [options]' \
        '' \
        'Options:' \
        '  --yes                    Install without interactive prompts' \
        '  --version <version>      FrankenPHP stable version (for example 1.12.7)' \
        '  --linux-build <type>     static (default) or gnu' \
        '  --help                   Show this help'
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --yes)
                ASSUME_YES=1
                shift
                ;;
            --version)
                if [[ "$#" -lt 2 ]]; then
                    die '--version requires a value'
                    return 1
                fi
                REQUESTED_VERSION="$(normalize_version "$2")" || return 1
                VERSION_OPTION_SET=1
                shift 2
                ;;
            --linux-build)
                if [[ "$#" -lt 2 ]]; then
                    die '--linux-build requires a value'
                    return 1
                fi
                case "$2" in
                    static|gnu)
                        LINUX_BUILD="$2"
                        LINUX_BUILD_OPTION_SET=1
                        ;;
                    *)
                        die "invalid Linux build: $2 (expected static or gnu)"
                        return 1
                        ;;
                esac
                shift 2
                ;;
            --help)
                SHOW_HELP=1
                shift
                ;;
            *)
                die "unknown option: $1"
                return 1
                ;;
        esac
    done
}

detect_platform() {
    local os="$1"
    local arch="$2"
    local linux_build="$3"

    case "$arch" in
        x86_64|amd64) PLATFORM_ARCH='x86_64' ;;
        arm64|aarch64) PLATFORM_ARCH='arm64' ;;
        *)
            die "unsupported architecture: $arch"
            return 1
            ;;
    esac

    case "$os" in
        Linux)
            PLATFORM_OS='linux'
            case "$linux_build" in
                static) ASSET_NAME="frankenphp-linux-${PLATFORM_ARCH/arm64/aarch64}" ;;
                gnu) ASSET_NAME="frankenphp-linux-${PLATFORM_ARCH/arm64/aarch64}-gnu" ;;
                *)
                    die "invalid Linux build: $linux_build"
                    return 1
                    ;;
            esac
            ;;
        Darwin)
            if [[ "$linux_build" != 'static' ]]; then
                die '--linux-build gnu is only valid on Linux'
                return 1
            fi
            PLATFORM_OS='darwin'
            ASSET_NAME="frankenphp-mac-$PLATFORM_ARCH"
            ;;
        *)
            die "unsupported operating system: $os"
            return 1
            ;;
    esac
}

has_glibc() {
    if command -v getconf >/dev/null 2>&1 && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
        return 0
    fi

    if command -v ldd >/dev/null 2>&1; then
        local output
        output="$(ldd --version 2>&1 || true)"
        [[ "$output" == *glibc* || "$output" == *GLIBC* || "$output" == *'GNU libc'* ]]
        return
    fi

    return 1
}

can_show_download_progress() {
    [[ -t 2 ]]
}

curl_to_file() {
    local url="$1"
    local destination="$2"
    local progress_label="$3"
    shift 3
    local attempt=1
    local max_attempts=4
    local status
    local -a output_options

    while ((attempt <= max_attempts)); do
        if [[ -n "$progress_label" ]] && can_show_download_progress; then
            if ((attempt == 1)); then
                printf 'Downloading %s\n' "$progress_label" >&2
            else
                printf 'Downloading %s (attempt %s/%s)\n' \
                    "$progress_label" "$attempt" "$max_attempts" >&2
            fi
            output_options=(--progress-bar)
        else
            output_options=(--silent)
        fi

        if curl --fail --show-error "${output_options[@]}" --location \
            --connect-timeout 15 "$@" "$url" -o "$destination"; then
            return 0
        else
            status=$?
        fi
        if ((attempt == max_attempts)); then
            die "download failed after $max_attempts attempts (curl exit $status): $url"
            return "$status"
        fi
        printf 'Download failed (attempt %s/%s); retrying...\n' "$attempt" "$max_attempts" >&2
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

download_file() {
    local url="$1"
    local destination="$2"
    local progress_label="${3-}"

    case "$url" in
        https://api.github.com/*|https://github.com/*|https://getcomposer.org/*|https://composer.github.io/*) ;;
        *)
            die "refusing download from unsupported URL: $url"
            return 1
            ;;
    esac

    curl_to_file "$url" "$destination" "$progress_label"
}

fetch_release_json() {
    local version="$1"
    local destination="$2"
    local url
    local attempt=1
    local max_attempts=4
    local status
    local response

    if [[ "$version" == 'latest' ]]; then
        url="$FRANKENPHP_API_BASE/latest"
    else
        version="$(normalize_version "$version")" || return 1
        url="$FRANKENPHP_API_BASE/tags/$version"
    fi

    if [[ "$destination" != '-' ]]; then
        curl_to_file "$url" "$destination" '' \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28'
        return
    fi

    while ((attempt <= max_attempts)); do
        if response="$(curl --fail --show-error --silent --location \
            --connect-timeout 15 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$url")"; then
            printf '%s\n' "$response"
            return 0
        else
            status=$?
        fi
        if ((attempt == max_attempts)); then
            die "GitHub release request failed after $max_attempts attempts (curl exit $status)"
            return "$status"
        fi
        printf 'GitHub release request failed (attempt %s/%s); retrying...\n' \
            "$attempt" "$max_attempts" >&2
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

parse_release() {
    local json_file="$1"
    local asset_name="$2"
    local record
    local tag
    local draft
    local prerelease
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
        function json_scalar(line, value) {
            value = line
            sub(/^[^:]*:[[:space:]]*/, "", value)
            sub(/[,]*[[:space:]]*$/, "", value)
            return value
        }
        /^[[:space:]]*"tag_name":[[:space:]]*"/ {
            tag_count++
            tag = json_string($0)
            next
        }
        /^[[:space:]]*"draft":[[:space:]]*/ {
            draft_count++
            draft = json_scalar($0)
            next
        }
        /^[[:space:]]*"prerelease":[[:space:]]*/ {
            prerelease_count++
            prerelease = json_scalar($0)
            next
        }
        /^[[:space:]]*"name":[[:space:]]*"/ {
            value = json_string($0)
            if (value == target) {
                matches++
                active = 1
            } else {
                active = 0
            }
            next
        }
        active && /^[[:space:]]*"digest":[[:space:]]*"/ {
            digest = json_string($0)
            next
        }
        active && /^[[:space:]]*"browser_download_url":[[:space:]]*"/ {
            url = json_string($0)
            active = 0
            next
        }
        END {
            if (tag_count != 1 || draft_count != 1 || prerelease_count != 1) exit 2
            if (matches != 1 || digest == "" || url == "") exit 2
            printf "%s\t%s\t%s\t%s\t%s\n", tag, draft, prerelease, digest, url
        }
    ' "$json_file")" || {
        die "release metadata must contain one stable release and one complete asset named $asset_name"
        return 1
    }

    IFS=$'\t' read -r tag draft prerelease digest url <<<"$record"
    normalize_version "$tag" >/dev/null || return 1
    if [[ "$draft" != 'false' ]]; then
        die 'release is a draft or has invalid draft metadata'
        return 1
    fi
    if [[ "$prerelease" != 'false' ]]; then
        die 'release is a prerelease or has invalid prerelease metadata'
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        die "asset has an invalid SHA-256 digest: $digest"
        return 1
    fi

    expected_url="https://github.com/php/frankenphp/releases/download/$tag/$asset_name"
    if [[ "$url" != "$expected_url" ]]; then
        die "asset URL does not match the official release URL: $url"
        return 1
    fi

    RESOLVED_TAG="$tag"
    ASSET_SHA256="${digest#sha256:}"
    ASSET_URL="$url"
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
        *)
            die "unsupported checksum algorithm: $algorithm"
            return 1
            ;;
    esac

    output="${output%%[[:space:]]*}"
    if [[ "$algorithm" == 'sha256' && ! "$output" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die 'checksum utility returned invalid SHA-256 output'
        return 1
    fi
    if [[ "$algorithm" == 'sha384' && ! "$output" =~ ^[0-9a-fA-F]{96}$ ]]; then
        die 'checksum utility returned invalid SHA-384 output'
        return 1
    fi
    printf '%s\n' "$output" | tr 'A-F' 'a-f'
}

verify_checksum() {
    local algorithm="$1"
    local expected="$2"
    local file="$3"
    local actual

    actual="$(calculate_checksum "$algorithm" "$file")" || return 1
    if [[ "$actual" != "$expected" ]]; then
        printf 'Error: %s checksum mismatch.\nExpected: %s\nActual:   %s\n' \
            "$algorithm" "$expected" "$actual" >&2
        return 1
    fi
}

open_terminal() {
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi

    if ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
        die 'no interactive terminal is available; run again with --yes'
        return 1
    fi
}

prompt_choice() {
    local prompt="$1"
    local default="$2"
    shift 2
    local choices=("$@")
    local answer
    local choice
    local valid
    local choices_label
    local index

    choices_label="${choices[0]}"
    for ((index = 1; index < ${#choices[@]}; index++)); do
        choices_label="$choices_label or ${choices[$index]}"
    done

    while true; do
        printf '%s [%s]: ' "$prompt" "$default" >&4
        if ! IFS= read -r answer <&3; then
            die 'interactive input ended unexpectedly'
            return 1
        fi
        [[ -n "$answer" ]] || answer="$default"

        valid=0
        for choice in "${choices[@]}"; do
            if [[ "$answer" == "$choice" ]]; then
                valid=1
                break
            fi
        done
        if [[ "$valid" -eq 1 ]]; then
            printf '%s\n' "$answer"
            return 0
        fi
        printf 'Please enter %s.\n' "$choices_label" >&4
    done
}

confirm_install() {
    local answer

    while true; do
        printf 'Continue? [Y/n]: ' >&4
        if ! IFS= read -r answer <&3; then
            die 'interactive input ended unexpectedly'
            return 1
        fi
        case "$answer" in
            ''|y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) printf 'Please enter y or n.\n' >&4 ;;
        esac
    done
}

preflight_project() {
    local project_root="$1"
    local candidate

    if [[ ! -d "$project_root" || ! -w "$project_root" ]]; then
        die "project directory is not writable: $project_root"
        return 1
    fi
    for candidate in "$project_root/.wari" "$project_root/wari"; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            printf 'Error: %s already exists.\nWari did not change any files.\n' "$candidate" >&2
            return 1
        fi
    done
}

is_safe_staging_path() {
    local project_root="$1"
    local path="$2"
    local parent
    local base

    [[ -n "$project_root" && -n "$path" ]] || return 1
    parent="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    [[ "$parent" == "$project_root" ]] || return 1
    [[ "$base" == .wari-install.?* ]] || return 1
    [[ "$path" != "$project_root" && "$path" != "$project_root/wari" ]]
}

create_staging() {
    local project_root="$1"

    STAGING_DIR="$(mktemp -d "$project_root/.wari-install.XXXXXX")"
    is_safe_staging_path "$project_root" "$STAGING_DIR" || {
        die 'mktemp returned an unsafe staging path'
        return 1
    }
}

cleanup() {
    local published_runtime="${PROJECT_ROOT:-}/.wari"
    local published_dispatcher="${PROJECT_ROOT:-}/wari"
    local staged_dispatcher="$published_runtime/wari"

    if [[ -n "${STAGING_DIR:-}" && -e "$STAGING_DIR" ]]; then
        if ! is_safe_staging_path "$PROJECT_ROOT" "$STAGING_DIR"; then
            printf 'Error: refusing to clean unsafe staging path: %s\n' "$STAGING_DIR" >&2
            return 1
        fi
        rm -rf -- "$STAGING_DIR"
    fi

    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        if [[ -e "$published_dispatcher" || -L "$published_dispatcher" ]]; then
            if [[ -e "$staged_dispatcher" ]]; then
                if [[ "$published_dispatcher" -ef "$staged_dispatcher" ]]; then
                    rm -f -- "$published_dispatcher"
                fi
            elif [[ "${PUBLISHED_DISPATCHER:-0}" -eq 1 ]]; then
                rm -f -- "$published_dispatcher"
            fi
        fi
        if [[ "${PUBLISHED_RUNTIME:-0}" -eq 1 && -d "$published_runtime" && ! -L "$published_runtime" ]]; then
            rm -rf -- "$published_runtime"
        fi
    fi
}

cleanup_on_exit() {
    local status=$?
    cleanup || true
    exit "$status"
}

require_safe_staging() {
    local staging="$1"

    if ! is_safe_staging_path "$PROJECT_ROOT" "$staging" || [[ ! -d "$staging" ]]; then
        die "unsafe or missing staging directory: $staging"
        return 1
    fi
}

install_frankenphp() {
    local staging="$1"
    local runtime_dir="$staging/runtime"
    local download="$runtime_dir/frankenphp.download"

    require_safe_staging "$staging" || return 1
    mkdir -p "$runtime_dir"
    download_file "$ASSET_URL" "$download" "FrankenPHP $RESOLVED_TAG" || return 1
    verify_checksum sha256 "$ASSET_SHA256" "$download" || return 1
    mv -- "$download" "$runtime_dir/frankenphp"
    chmod 755 "$runtime_dir/frankenphp"
}

install_composer() {
    local staging="$1"
    local setup="$staging/composer-setup.php"
    local checksum_file="$staging/composer-setup.sha384"
    local expected

    require_safe_staging "$staging" || return 1
    if [[ ! -x "$staging/runtime/frankenphp" ]]; then
        die 'FrankenPHP must be installed before Composer'
        return 1
    fi

    download_file 'https://getcomposer.org/installer' "$setup" 'Composer' || return 1
    download_file 'https://composer.github.io/installer.sig' "$checksum_file" || return 1
    expected="$(tr -d '[:space:]' <"$checksum_file")"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{96}$ ]]; then
        die 'Composer installer checksum is invalid'
        return 1
    fi
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    verify_checksum sha384 "$expected" "$setup" || return 1

    "$staging/runtime/frankenphp" php-cli "$setup" \
        --quiet \
        --install-dir="$staging/runtime" \
        --filename=composer.phar || return 1

    if [[ ! -f "$staging/runtime/composer.phar" ]]; then
        die 'Composer installer did not create composer.phar'
        return 1
    fi
    rm -f -- "$setup" "$checksum_file"
}

generate_wrappers() {
    local wari_dir="$1"

    if [[ ! -d "$wari_dir/runtime" ]]; then
        die "runtime directory is missing: $wari_dir/runtime"
        return 1
    fi

    cat >"$wari_dir/runtime/php-proxy.php" <<'WARI_PHP_PROXY'
<?php

declare(strict_types=1);

$mode = $argv[1] ?? '';
$arguments = array_slice($argv, 2);

switch ($mode) {
    case 'version':
        printf("PHP %s (cli)\n", PHP_VERSION);
        break;

    case 'eval':
        if ($arguments === []) {
            fwrite(STDERR, "Error: -r requires PHP code.\n");
            exit(2);
        }
        $code = array_shift($arguments);
        $argv = array_merge(['Standard input code'], $arguments);
        $argc = count($argv);
        $_SERVER['argv'] = $argv;
        $_SERVER['argc'] = $argc;
        eval($code);
        break;

    case 'modules':
        $modules = get_loaded_extensions(false);
        sort($modules, SORT_STRING | SORT_FLAG_CASE);
        $zendModules = get_loaded_extensions(true);
        sort($zendModules, SORT_STRING | SORT_FLAG_CASE);
        echo "[PHP Modules]\n", implode("\n", $modules), "\n\n[Zend Modules]\n";
        if ($zendModules !== []) {
            echo implode("\n", $zendModules), "\n";
        }
        break;

    case 'info':
        phpinfo(INFO_ALL);
        break;

    default:
        fwrite(STDERR, "Error: unsupported Wari PHP helper mode.\n");
        exit(2);
}
WARI_PHP_PROXY

    cat >"$wari_dir/php" <<'WARI_PHP'
#!/usr/bin/env bash
set -Eeuo pipefail

WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

arguments=("$@")
filtered_arguments=()
index=0
while ((index < ${#arguments[@]})); do
    argument="${arguments[$index]}"
    case "$argument" in
        -d)
            if ((index + 1 >= ${#arguments[@]})); then
                printf 'Error: -d requires a setting; FrankenPHP php-cli cannot apply -d options.\n' >&2
                exit 2
            fi
            setting="${arguments[$((index + 1))]}"
            if [[ "${WARI_COMPOSER_CONTEXT:-0}" != 1 ]]; then
                printf 'Wari warning: ignored unsupported PHP option: -d %s\n' "$setting" >&2
            fi
            index=$((index + 2))
            ;;
        -d*)
            setting="${argument#-d}"
            if [[ "${WARI_COMPOSER_CONTEXT:-0}" != 1 ]]; then
                printf 'Wari warning: ignored unsupported PHP option: -d%s\n' "$setting" >&2
            fi
            index=$((index + 1))
            ;;
        *)
            filtered_arguments+=("$argument")
            index=$((index + 1))
            ;;
    esac
done

case "${filtered_arguments[0]-}" in
    --version|-v)
        exec "$WARI_DIR/runtime/frankenphp" php-cli \
            "$WARI_DIR/runtime/php-proxy.php" version
        ;;
    -r)
        if ((${#filtered_arguments[@]} < 2)); then
            printf 'Error: -r requires PHP code.\n' >&2
            exit 2
        fi
        exec "$WARI_DIR/runtime/frankenphp" php-cli \
            "$WARI_DIR/runtime/php-proxy.php" eval \
            "${filtered_arguments[@]:1}"
        ;;
    -m)
        exec "$WARI_DIR/runtime/frankenphp" php-cli \
            "$WARI_DIR/runtime/php-proxy.php" modules
        ;;
    -i)
        exec "$WARI_DIR/runtime/frankenphp" php-cli \
            "$WARI_DIR/runtime/php-proxy.php" info
        ;;
esac

exec "$WARI_DIR/runtime/frankenphp" php-cli "${filtered_arguments[@]}"
WARI_PHP

    cat >"$wari_dir/composer" <<'WARI_COMPOSER'
#!/usr/bin/env bash
set -Eeuo pipefail

WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$WARI_DIR")"
cd -- "$PROJECT_ROOT"

export PHP_BINARY="$WARI_DIR/php"
export PATH="$WARI_DIR:$PATH"
export WARI_COMPOSER_CONTEXT=1
exec "$WARI_DIR/php" "$WARI_DIR/runtime/composer.phar" "$@"
WARI_COMPOSER

    cat >"$wari_dir/serve" <<'WARI_SERVE'
#!/usr/bin/env bash
set -Eeuo pipefail

WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$WARI_DIR")"
cd -- "$PROJECT_ROOT"

if [[ ! -d "$PROJECT_ROOT/public" ]]; then
    printf 'Error: public directory does not exist: %s/public\n' "$PROJECT_ROOT" >&2
    exit 1
fi

exec "$WARI_DIR/runtime/frankenphp" php-server \
    --listen 127.0.0.1:8000 \
    --root "$PROJECT_ROOT/public"
WARI_SERVE

    cat >"$wari_dir/frankenphp" <<'WARI_FRANKENPHP'
#!/usr/bin/env bash
set -Eeuo pipefail

WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$WARI_DIR")"
cd -- "$PROJECT_ROOT"

exec "$WARI_DIR/runtime/frankenphp" "$@"
WARI_FRANKENPHP

    chmod 755 \
        "$wari_dir/php" \
        "$wari_dir/composer" \
        "$wari_dir/serve" \
        "$wari_dir/frankenphp"
}

generate_dispatcher() {
    local wari_dir="$1"

    if [[ ! -d "$wari_dir" ]]; then
        die "Wari directory is missing: $wari_dir"
        return 1
    fi

    cat >"$wari_dir/wari" <<'WARI_DISPATCHER'
#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    printf '%s\n' \
        'Usage: ./wari <command> [arguments]' \
        '' \
        'Commands:' \
        '  php          Run project-local PHP' \
        '  composer     Run project-local Composer' \
        '  serve        Serve ./public at http://127.0.0.1:8000' \
        '  frankenphp   Run the bundled FrankenPHP binary' \
        '  help         Show this help'
}

WARI_PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WARI_RUNTIME_DIR="$WARI_PROJECT_ROOT/.wari"

if [[ ! -d "$WARI_RUNTIME_DIR" ]]; then
    printf 'Error: Wari runtime directory does not exist: %s\n' "$WARI_RUNTIME_DIR" >&2
    exit 1
fi

command_name="${1-}"
case "$command_name" in
    ''|help|--help|-h)
        usage
        ;;
    php|composer|serve|frankenphp)
        shift
        exec "$WARI_RUNTIME_DIR/$command_name" "$@"
        ;;
    *)
        printf 'Error: Unknown Wari command: %s\n\n' "$command_name" >&2
        usage >&2
        exit 1
        ;;
esac
WARI_DISPATCHER

    chmod 755 "$wari_dir/wari"
}

publish_install() {
    local staging="$1"
    local project_root="$2"
    local runtime_destination="$project_root/.wari"
    local dispatcher_source="$runtime_destination/wari"
    local dispatcher_destination="$project_root/wari"

    require_safe_staging "$staging" || return 1
    if [[ -e "$runtime_destination" || -L "$runtime_destination" ||
        -e "$dispatcher_destination" || -L "$dispatcher_destination" ]]; then
        die 'Wari destination appeared while installation was in progress'
        return 1
    fi

    mv -- "$staging" "$runtime_destination" || return 1
    STAGING_DIR=''
    PUBLISHED_RUNTIME=1

    if [[ ! -f "$dispatcher_source" || ! -x "$dispatcher_source" || -L "$dispatcher_source" ]]; then
        die 'generated Wari dispatcher is missing or invalid'
        return 1
    fi
    if ! ln "$dispatcher_source" "$dispatcher_destination"; then
        die 'could not publish Wari dispatcher without overwriting an existing path'
        return 1
    fi
    PUBLISHED_DISPATCHER=1
}

json_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

detect_installed_versions() {
    local wari_dir="$1"
    local php_output
    local frankenphp_output
    local composer_output

    php_output="$("$wari_dir/php" --version)" || return 1
    frankenphp_output="$("$wari_dir/frankenphp" version)" || return 1
    composer_output="$("$wari_dir/composer" --version)" || return 1

    INSTALLED_PHP_VERSION="$(printf '%s\n' "$php_output" | sed -n 's/^PHP \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n '1p')"
    INSTALLED_FRANKENPHP_VERSION="$(printf '%s\n' "$frankenphp_output" | sed -n 's/.*FrankenPHP \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n '1p')"
    INSTALLED_COMPOSER_VERSION="$(printf '%s\n' "$composer_output" | sed -n 's/^Composer version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n '1p')"

    if [[ -z "$INSTALLED_PHP_VERSION" ]]; then
        die 'could not detect the installed PHP version'
        return 1
    fi
    if [[ -z "$INSTALLED_FRANKENPHP_VERSION" ]]; then
        die 'could not detect the installed FrankenPHP version'
        return 1
    fi
    if [[ -z "$INSTALLED_COMPOSER_VERSION" ]]; then
        die 'could not detect the installed Composer version'
        return 1
    fi
}

write_manifest() {
    local wari_dir="$1"
    local installed_at
    local linux_build_json

    installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ "$PLATFORM_OS" == 'linux' ]]; then
        linux_build_json="\"$(json_escape "$LINUX_BUILD")\""
    else
        linux_build_json='null'
    fi

    {
        printf '{\n'
        printf '  "wari_version": "%s",\n' "$(json_escape "$WARI_VERSION")"
        printf '  "frankenphp_version": "%s",\n' "$(json_escape "$INSTALLED_FRANKENPHP_VERSION")"
        printf '  "php_version": "%s",\n' "$(json_escape "$INSTALLED_PHP_VERSION")"
        printf '  "composer_version": "%s",\n' "$(json_escape "$INSTALLED_COMPOSER_VERSION")"
        printf '  "os": "%s",\n' "$(json_escape "$PLATFORM_OS")"
        printf '  "architecture": "%s",\n' "$(json_escape "$PLATFORM_ARCH")"
        printf '  "linux_build": %s,\n' "$linux_build_json"
        printf '  "asset": "%s",\n' "$(json_escape "$ASSET_NAME")"
        printf '  "asset_url": "%s",\n' "$(json_escape "$ASSET_URL")"
        printf '  "asset_sha256": "%s",\n' "$(json_escape "$ASSET_SHA256")"
        printf '  "checksum_verified": true,\n'
        printf '  "slsa_verified": false,\n'
        printf '  "installed_at": "%s"\n' "$(json_escape "$installed_at")"
        printf '}\n'
    } >"$wari_dir/manifest.json"
}

run_smoke_checks() {
    local wari_dir="$1"

    "$wari_dir/php" --version >/dev/null
    "$wari_dir/composer" --version >/dev/null
    "$wari_dir/frankenphp" version >/dev/null
    "$wari_dir/php" -r \
        '$data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR); exit(is_array($data) ? 0 : 1);' \
        "$wari_dir/manifest.json" >/dev/null
}

run_public_smoke_checks() {
    local project_root="$1"
    local dispatcher="$project_root/wari"

    "$dispatcher" php --version >/dev/null || return
    "$dispatcher" composer --version >/dev/null || return
    "$dispatcher" frankenphp version >/dev/null || return
    "$dispatcher" php -r \
        '$data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR); exit(is_array($data) ? 0 : 1);' \
        "$project_root/.wari/manifest.json" >/dev/null || return
}

require_commands() {
    local command_name

    for command_name in curl uname mktemp chmod mv ln sed awk tr dirname basename date; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            die "required command not found: $command_name"
            return 1
        fi
    done

    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        die 'no SHA-256 checksum utility found'
        return 1
    fi
    if ! command -v sha384sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        die 'no SHA-384 checksum utility found'
        return 1
    fi
}

prompt_value() {
    local prompt="$1"
    local answer

    while true; do
        printf '%s: ' "$prompt" >&4
        if ! IFS= read -r answer <&3; then
            die 'interactive input ended unexpectedly'
            return 1
        fi
        if [[ -n "$answer" ]]; then
            printf '%s\n' "$answer"
            return 0
        fi
        printf 'A value is required.\n' >&4
    done
}

collect_interactive_choices() {
    local version_choice
    local build_choice

    printf '\nWari installer\n\nProject:      %s\nPlatform:     %s %s\n\n' \
        "$PROJECT_ROOT" "$PLATFORM_OS" "$PLATFORM_ARCH" >&4
    if [[ "$VERSION_OPTION_SET" -eq 0 ]]; then
        printf 'FrankenPHP:\n  1) Latest stable (recommended)\n  2) Specific stable version\n' >&4
        version_choice="$(prompt_choice 'Choice' 1 1 2)" || return 1
        if [[ "$version_choice" == '2' ]]; then
            REQUESTED_VERSION="$(normalize_version "$(prompt_value 'FrankenPHP version')")" || return 1
        else
            REQUESTED_VERSION='latest'
        fi
    fi

    if [[ "$PLATFORM_OS" == 'linux' && "$LINUX_BUILD_OPTION_SET" -eq 0 ]]; then
        printf '\nLinux build:\n  1) Fully static (recommended)\n  2) GNU/glibc\n' >&4
        build_choice="$(prompt_choice 'Choice' 1 1 2)" || return 1
        case "$build_choice" in
            1) LINUX_BUILD='static' ;;
            2) LINUX_BUILD='gnu' ;;
        esac
        detect_platform Linux "$(uname -m)" "$LINUX_BUILD" || return 1
    fi

    printf '\nFrankenPHP:  %s\n' "$REQUESTED_VERSION" >&4
    if [[ "$PLATFORM_OS" == 'linux' ]]; then
        printf 'Linux build: %s\n' "$LINUX_BUILD" >&4
    fi
    printf 'Composer:    latest stable\nRuntime:      %s/.wari\nCommand:      %s/wari\n\n' \
        "$PROJECT_ROOT" "$PROJECT_ROOT" >&4
}

reset_runtime_state() {
    ASSUME_YES=0
    REQUESTED_VERSION='latest'
    LINUX_BUILD='static'
    SHOW_HELP=0
    VERSION_OPTION_SET=0
    LINUX_BUILD_OPTION_SET=0
    PLATFORM_OS=''
    PLATFORM_ARCH=''
    ASSET_NAME=''
    RESOLVED_TAG=''
    ASSET_URL=''
    ASSET_SHA256=''
    PROJECT_ROOT=''
    STAGING_DIR=''
    PUBLISHED_RUNTIME=0
    PUBLISHED_DISPATCHER=0
    INSTALLED_PHP_VERSION=''
    INSTALLED_FRANKENPHP_VERSION=''
    INSTALLED_COMPOSER_VERSION=''
}

main() {
    local release_json

    reset_runtime_state
    parse_args "$@"
    if [[ "$SHOW_HELP" -eq 1 ]]; then
        usage
        return 0
    fi

    PROJECT_ROOT="$(pwd -P)"
    preflight_project "$PROJECT_ROOT" || return 1
    require_commands || return 1
    detect_platform "$(uname -s)" "$(uname -m)" "$LINUX_BUILD" || return 1

    if [[ "$ASSUME_YES" -eq 0 ]]; then
        open_terminal || return 1
        collect_interactive_choices || return 1
        if ! confirm_install; then
            printf 'Installation cancelled.\n' >&4
            return 0
        fi
    fi

    if [[ "$PLATFORM_OS" == 'linux' && "$LINUX_BUILD" == 'gnu' ]] && ! has_glibc; then
        die 'GNU build requires glibc; choose the static Linux build instead'
        return 1
    fi

    printf 'Resolving FrankenPHP release...\n'
    release_json="$(fetch_release_json "$REQUESTED_VERSION" -)" || return 1
    parse_release <(printf '%s\n' "$release_json") "$ASSET_NAME" || return 1

    create_staging "$PROJECT_ROOT" || return 1
    trap cleanup_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    printf 'Downloading and verifying FrankenPHP %s...\n' "$RESOLVED_TAG"
    install_frankenphp "$STAGING_DIR" || return 1
    printf 'Downloading and verifying Composer...\n'
    install_composer "$STAGING_DIR" || return 1
    generate_wrappers "$STAGING_DIR" || return 1
    generate_dispatcher "$STAGING_DIR" || return 1
    detect_installed_versions "$STAGING_DIR" || return 1
    write_manifest "$STAGING_DIR" || return 1
    run_smoke_checks "$STAGING_DIR" || return 1

    publish_install "$STAGING_DIR" "$PROJECT_ROOT" || return 1
    run_public_smoke_checks "$PROJECT_ROOT" || return $?
    rm -f -- "$PROJECT_ROOT/.wari/wari" || return 1
    PUBLISHED_DISPATCHER=0
    PUBLISHED_RUNTIME=0
    trap - EXIT INT TERM HUP

    printf '\nInstalled successfully.\n\n'
    printf 'PHP:          %s\n' "$INSTALLED_PHP_VERSION"
    printf 'FrankenPHP:   %s\n' "$INSTALLED_FRANKENPHP_VERSION"
    printf 'Composer:     %s\n' "$INSTALLED_COMPOSER_VERSION"
    printf 'Checksum:     verified\n'
    printf 'SLSA:         not checked\n\n'
    printf 'Try:\n'
    printf '  ./wari php --version\n'
    printf '  ./wari composer --version\n'
    printf '  ./wari serve\n'
}

if [[ -z "${BASH_SOURCE[0]-}" || "${BASH_SOURCE[0]-}" == "$0" ]]; then
    main "$@"
fi
