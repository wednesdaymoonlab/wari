#!/usr/bin/env bash
set -Eeuo pipefail

WARI_VERSION='0.4.2'
WARI_LEGACY_DISPATCHER_SHA256='e79b82db037f7ee0a0907b27c2a893a53b7677a1ace25a1e6e953ff5aedbac43'

INITIALIZER_ANSI_RESET=$'\033[0m'
INITIALIZER_ANSI_GREEN=$'\033[1;92m'

initializer_color_enabled() {
    local file_descriptor="${1:-1}"

    [[ -z "${NO_COLOR+x}" ]] || return 1
    case "${WARI_COLOR:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [[ "${TERM:-}" != dumb && -t "$file_descriptor" ]]
}

initializer_logo() {
    if initializer_color_enabled; then
        printf '%b' "$INITIALIZER_ANSI_GREEN"
    fi
    printf '%s\n' \
        ' _       __ ___    ____   ____' \
        '| |     / //   |  / __ \ /  _/' \
        '| | /| / // /| | / /_/ / / /' \
        '| |/ |/ // ___ |/ _, _/_/ /' \
        '|__/|__//_/  |_/_/ |_|/___/'
    if initializer_color_enabled; then
        printf '%b' "$INITIALIZER_ANSI_RESET"
    fi
    printf '%33s\n' "v$WARI_VERSION"
}

initializer_banner() {
    if initializer_color_enabled; then
        printf '%b' "$INITIALIZER_ANSI_GREEN"
    fi
    printf '+ %-28s ------------------\n' "$1"
    if initializer_color_enabled; then
        printf '%b' "$INITIALIZER_ANSI_RESET"
    fi
}

initializer_status() {
    if initializer_color_enabled; then
        printf '  %b[ OK ]%b %-14s %s\n' \
            "$INITIALIZER_ANSI_GREEN" "$INITIALIZER_ANSI_RESET" "$1" "$2"
    else
        printf '  [ OK ] %-14s %s\n' "$1" "$2"
    fi
}

initializer_error() {
    if initializer_color_enabled 2; then
        printf '  %b[FAIL]%b %s\n' \
            $'\033[1;91m' "$INITIALIZER_ANSI_RESET" "$1" >&2
    else
        printf '  [FAIL] %s\n' "$1" >&2
    fi
}

die() { initializer_error "$1"; return 1; }
can_show_download_progress() { [[ -t 2 ]]; }

validate_initializer_semver() {
    [[ "${1-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        die "invalid semantic version: ${1-}"
        return 1
    }
}

curl_to_file() {
    local url="$1" destination="$2" progress_label="$3"
    shift 3
    local attempt=1 max_attempts=4 status effective_url
    local -a output_options
    while ((attempt <= max_attempts)); do
        if [[ -n "$progress_label" ]] && can_show_download_progress; then
            output_options=(--progress-bar)
        else
            output_options=(--silent)
        fi
        if effective_url="$(curl --fail --show-error "${output_options[@]}" \
            --location --proto '=https' --proto-redir '=https' \
            --write-out '%{url_effective}' --connect-timeout 15 \
            "$@" "$url" -o "$destination")"; then
            if validate_initializer_effective_url "$url" "$effective_url"; then
                return 0
            fi
            rm -f -- "$destination"
            return 1
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

validate_initializer_effective_url() {
    local initial_url="$1"
    local effective_url="$2"

    case "$initial_url" in
        https://raw.githubusercontent.com/wednesdaymoonlab/wari/*)
            [[ "$effective_url" == "$initial_url" ]]
            ;;
        *) return 1 ;;
    esac || {
        die "download redirected to an unsupported URL: $effective_url"
        return 1
    }
}

download_file() {
    local url="$1" destination="$2" progress_label="${3-}"
    case "$url" in
        https://api.github.com/*|https://github.com/*|\
        https://raw.githubusercontent.com/wednesdaymoonlab/wari/*) ;;
        *) die "refusing download from unsupported URL: $url"; return 1 ;;
    esac
    curl_to_file "$url" "$destination" "$progress_label"
}

calculate_checksum() {
    local algorithm="$1" file="$2" output
    [[ "$algorithm" == sha256 ]] || {
        die "unsupported checksum algorithm: $algorithm"; return 1;
    }
    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum "$file")"
    elif command -v shasum >/dev/null 2>&1; then
        output="$(shasum -a 256 "$file")"
    else
        die 'no SHA-256 checksum utility found'; return 1
    fi
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-fA-F]{64}$ ]] || {
        die 'checksum utility returned invalid SHA-256 output'; return 1;
    }
    printf '%s\n' "$output" | tr 'A-F' 'a-f'
}

verify_checksum() {
    local algorithm="$1" expected="$2" file="$3" actual
    actual="$(calculate_checksum "$algorithm" "$file")" || return 1
    [[ "$actual" == "$expected" ]] || {
        initializer_error "$algorithm checksum mismatch."
        printf '  Expected: %s\n  Actual:   %s\n' "$expected" "$actual" >&2
        return 1
    }
}

write_wari_ignore_block() {
    printf '%s\n' '# Wari local runtime' '/.wari/' '/.wari-install.*' \
        '/.wari-backup.*' '/.wari-update.*' '/.wari-setup.lock'
}

ensure_gitignore_block() {
    local project_root="$1" gitignore="$1/.gitignore" temporary
    if [[ -L "$gitignore" || ( -e "$gitignore" && ! -f "$gitignore" ) ]]; then
        die "cannot manage non-regular .gitignore: $gitignore"; return 1
    fi
    if [[ -f "$gitignore" ]] && awk '
        $0 == "# Wari local runtime" { marker++ }
        $0 == "/.wari/" { runtime++ }
        $0 == "/.wari-install.*" { install++ }
        $0 == "/.wari-backup.*" { backup++ }
        $0 == "/.wari-update.*" { update++ }
        $0 == "/.wari-setup.lock" { lock++ }
        END { exit !(marker == 1 && runtime >= 1 && install >= 1 &&
            backup >= 1 && update >= 1 && lock >= 1) }
    ' "$gitignore"; then
        return 0
    fi
    temporary="$(mktemp "$project_root/.wari-install.gitignore.XXXXXX")"
    if [[ -f "$gitignore" ]]; then
        cp "$gitignore" "$temporary" || { rm -f -- "$temporary"; return 1; }
        if [[ -s "$temporary" && "$(tail -c 1 "$temporary" 2>/dev/null || true)" != '' ]]; then
            printf '\n' >>"$temporary"
        fi
        [[ ! -s "$temporary" ]] || printf '\n' >>"$temporary"
    fi
    write_wari_ignore_block >>"$temporary" || { rm -f -- "$temporary"; return 1; }
    mv -- "$temporary" "$gitignore"
}

fetch_tagged_launcher() {
    local staging="$1"
    local version="$2"
    local url

    validate_initializer_semver "$version" || return 1
    url="https://raw.githubusercontent.com/wednesdaymoonlab/wari/v$version/wari"
    download_file "$url" "$staging/wari" "Wari $version launcher" || return 1
    chmod 755 "$staging/wari"
}

copy_local_launcher() {
    local staging="$1"
    local source_directory="$2"
    local physical_source

    [[ -d "$source_directory" && ! -L "$source_directory" ]] || {
        die "invalid local Wari source directory: $source_directory"
        return 1
    }
    physical_source="$(CDPATH= cd -- "$source_directory" && pwd -P)" || return 1
    [[ -f "$physical_source/wari" && ! -L "$physical_source/wari" ]] || {
        die "local Wari source has no regular launcher: $physical_source/wari"
        return 1
    }
    cp "$physical_source/wari" "$staging/wari" || return 1
    chmod 755 "$staging/wari"
}

generate_staged_lock() {
    local staging="$1"
    local frankenphp_request="$2"
    local composer_request="$3"
    local linux_build="$4"
    local -a generator_args

    generator_args=(
        --generate-lock "$staging/wari.lock"
        --linux-build "$linux_build"
        --lock-version 2
    )
    [[ -z "$frankenphp_request" ]] || generator_args+=(--frankenphp "$frankenphp_request")
    [[ -z "$composer_request" ]] || generator_args+=(--composer "$composer_request")
    bash "$staging/wari" "${generator_args[@]}"
}

fetch_tracked_files() {
    local staging="$1"
    local selected_wari_version="$2"
    local local_source="$3"
    local frankenphp_request="$4"
    local composer_request="$5"
    local linux_build="$6"
    local staged_version

    if [[ -n "$local_source" ]]; then
        copy_local_launcher "$staging" "$local_source" || return 1
    else
        fetch_tagged_launcher "$staging" "$selected_wari_version" || return 1
    fi
    staged_version="$(bash "$staging/wari" --version-value)" || return 1
    validate_initializer_semver "$staged_version" || return 1
    if [[ -z "$local_source" && "$staged_version" != "$selected_wari_version" ]]; then
        die 'downloaded Wari launcher version does not match the requested tag'
        return 1
    fi
    generate_staged_lock "$staging" "$frankenphp_request" \
        "$composer_request" "$linux_build"
}

is_recognized_legacy_layout() {
    local project_root="$1" manifest="$1/.wari/manifest.json" dispatcher_sha
    [[ -d "$project_root/.wari" && ! -L "$project_root/.wari" &&
        -f "$manifest" && ! -L "$manifest" &&
        -x "$project_root/.wari/wari" && ! -L "$project_root/.wari/wari" &&
        -f "$project_root/wari" && ! -L "$project_root/wari" &&
        "$project_root/wari" -ef "$project_root/.wari/wari" &&
        ! -e "$project_root/wari.lock" && ! -L "$project_root/wari.lock" ]] || return 1
    dispatcher_sha="$(calculate_checksum sha256 "$project_root/.wari/wari")" || return 1
    [[ "$dispatcher_sha" == "$WARI_LEGACY_DISPATCHER_SHA256" ]] || return 1
    awk '
        /"wari_version"[[:space:]]*:[[:space:]]*"0\.1\.0"/ { version++ }
        /"checksum_verified"[[:space:]]*:[[:space:]]*true/ { checksum++ }
        END { exit !(version == 1 && checksum == 1) }
    ' "$manifest"
}

confirm_initializer() {
    local answer
    if ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
        die 'initialization requires confirmation; pass --yes for automation'; return 2
    fi
    printf 'Add Wari tracked files to this project? [Y/n]: ' >&4
    IFS= read -r answer <&3 || return 2
    case "$answer" in ''|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

initializer_main() (
    local assume_yes=0 migrate=0 project_root staging confirm_status
    local published_wari=0 published_lock=0 legacy_backup=''
    local selected_wari_version="$WARI_VERSION"
    local frankenphp_request='' composer_request='' linux_build='static'
    local local_source=''
    local seen_wari=0 seen_frankenphp=0 seen_composer=0 seen_linux_build=0
    local seen_local_source=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --yes) assume_yes=1; shift ;;
            --migrate) migrate=1; shift ;;
            --wari)
                [[ "$seen_wari" -eq 0 && "$#" -ge 2 ]] || {
                    die 'invalid or duplicate --wari option'; return 2;
                }
                seen_wari=1; selected_wari_version="$2"; shift 2
                ;;
            --frankenphp)
                [[ "$seen_frankenphp" -eq 0 && "$#" -ge 2 ]] || {
                    die 'invalid or duplicate --frankenphp option'; return 2;
                }
                seen_frankenphp=1; frankenphp_request="$2"; shift 2
                ;;
            --composer)
                [[ "$seen_composer" -eq 0 && "$#" -ge 2 ]] || {
                    die 'invalid or duplicate --composer option'; return 2;
                }
                seen_composer=1; composer_request="$2"; shift 2
                ;;
            --linux-build)
                [[ "$seen_linux_build" -eq 0 && "$#" -ge 2 ]] || {
                    die 'invalid or duplicate --linux-build option'; return 2;
                }
                seen_linux_build=1; linux_build="$2"; shift 2
                ;;
            --local-source)
                [[ "$seen_local_source" -eq 0 && "$#" -ge 2 ]] || {
                    die 'invalid or duplicate --local-source option'; return 2;
                }
                seen_local_source=1; local_source="$2"; shift 2
                ;;
            --help|-h)
                printf '%s\n' \
                    'Usage: install.sh [--yes] [--migrate] [--wari VERSION]' \
                    '       [--frankenphp VERSION] [--composer VERSION]' \
                    '       [--linux-build static|gnu] [--local-source DIRECTORY]' '' \
                    'Add the tracked Wari launcher and lock to the current project.' \
                    'The lock is generated from official upstream metadata.' \
                    'Use --migrate only for a recognized generated Wari 0.1 layout.'
                return 0 ;;
            *) die "unknown initializer option: $1"; return 2 ;;
        esac
    done
    [[ "$seen_wari" -eq 0 || "$seen_local_source" -eq 0 ]] || {
        die '--wari and --local-source cannot be used together'; return 2;
    }
    validate_initializer_semver "$selected_wari_version" || return 2
    [[ -z "$frankenphp_request" ]] || validate_initializer_semver "$frankenphp_request" || return 2
    [[ -z "$composer_request" ]] || validate_initializer_semver "$composer_request" || return 2
    [[ "$linux_build" == static || "$linux_build" == gnu ]] || {
        die "invalid Linux build: $linux_build"; return 2;
    }
    project_root="$(pwd -P)"
    if [[ "$migrate" -eq 1 ]]; then
        is_recognized_legacy_layout "$project_root" || {
            die 'existing paths are not a recognized legacy Wari layout'; return 1;
        }
    elif [[ -e "$project_root/wari" || -L "$project_root/wari" ||
        -e "$project_root/wari.lock" || -L "$project_root/wari.lock" ]]; then
        die 'wari or wari.lock already exists; Wari did not change any files'; return 1
    fi
    if [[ "$assume_yes" -ne 1 ]]; then
        if confirm_initializer; then :; else
            confirm_status=$?
            if [[ "$confirm_status" -eq 1 ]]; then
                printf 'Wari initialization cancelled.\n'; return 0
            fi
            return 1
        fi
    fi

    staging="$(mktemp -d "$project_root/.wari-install.XXXXXX")"
    cleanup_initializer() {
        local status=$?
        [[ "$published_lock" -ne 1 ]] || rm -f -- "$project_root/wari.lock"
        [[ "$published_wari" -ne 1 ]] || rm -f -- "$project_root/wari"
        if [[ "$migrate" -eq 1 && -n "$legacy_backup" &&
            -f "$legacy_backup" && ! -e "$project_root/wari" ]]; then
            ln "$legacy_backup" "$project_root/wari" || true
        fi
        case "$staging" in "$project_root"/.wari-install.?*) rm -rf -- "$staging" ;; esac
        exit "$status"
    }
    trap cleanup_initializer EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

    fetch_tracked_files "$staging" "$selected_wari_version" "$local_source" \
        "$frankenphp_request" "$composer_request" "$linux_build" || return 1
    [[ -f "$staging/wari" && ! -L "$staging/wari" && -x "$staging/wari" ]] || {
        die 'downloaded Wari launcher is invalid'; return 1;
    }
    [[ -s "$staging/wari.lock" && ! -L "$staging/wari.lock" ]] || {
        die 'downloaded Wari lock is invalid'; return 1;
    }
    bash "$staging/wari" --validate-pair "$staging/wari.lock" || {
        die 'downloaded Wari launcher and lock do not match'; return 1;
    }
    if [[ "$migrate" -eq 1 ]]; then
        legacy_backup="$staging/wari.legacy"
        ln "$project_root/wari" "$legacy_backup" || return 1
        rm -f -- "$project_root/wari" || return 1
    fi
    trap '' INT TERM HUP
    if ! mv -- "$staging/wari" "$project_root/wari"; then
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        return 1
    fi
    published_wari=1
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    trap '' INT TERM HUP
    if ! mv -- "$staging/wari.lock" "$project_root/wari.lock"; then
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        return 1
    fi
    published_lock=1
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    ensure_gitignore_block "$project_root" || return 1
    [[ -z "$legacy_backup" ]] || rm -f -- "$legacy_backup"
    rmdir -- "$staging"
    published_wari=0; published_lock=0
    trap - EXIT INT TERM HUP
    initializer_logo
    printf '\n'
    initializer_banner 'WARI ADDED'
    printf '\n'
    initializer_status Launcher wari
    initializer_status 'Lock file' wari.lock
    initializer_status 'Git ignore' updated
    printf '\n'
    initializer_banner NEXT
    printf '\n  ./wari setup\n\nCommit these files:\n'
    printf '  wari\n  wari.lock\n  .gitignore\n'
)

if [[ -z "${BASH_SOURCE[0]-}" || "${BASH_SOURCE[0]-}" == "$0" ]]; then
    initializer_main "$@"
fi
