#!/usr/bin/env bash
set -Eeuo pipefail

WARI_VERSION='0.2.0'
WARI_LEGACY_DISPATCHER_SHA256='e79b82db037f7ee0a0907b27c2a893a53b7677a1ace25a1e6e953ff5aedbac43'

die() { printf 'Error: %s\n' "$1" >&2; return 1; }
can_show_download_progress() { [[ -t 2 ]]; }

curl_to_file() {
    local url="$1" destination="$2" progress_label="$3"
    shift 3
    local attempt=1 max_attempts=4 status
    local -a output_options
    while ((attempt <= max_attempts)); do
        if [[ -n "$progress_label" ]] && can_show_download_progress; then
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
        printf 'Download failed (attempt %s/%s); retrying...\n' \
            "$attempt" "$max_attempts" >&2
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

download_file() {
    local url="$1" destination="$2" progress_label="${3-}"
    case "$url" in
        https://api.github.com/*|https://github.com/*) ;;
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
        printf 'Error: %s checksum mismatch.\nExpected: %s\nActual:   %s\n' \
            "$algorithm" "$expected" "$actual" >&2
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

read_wari_release_asset() {
    local json_file="$1" asset_name="$2" record digest url
    record="$(awk -v target="$asset_name" '
        function string_value(line, value) {
            value = line; sub(/^[^:]*:[[:space:]]*"/, "", value)
            sub(/"[,]*[[:space:]]*$/, "", value); return value
        }
        /^[[:space:]]*"name":[[:space:]]*"/ {
            value = string_value($0)
            if (value == target) { matches++; active = 1 } else { active = 0 }
            next
        }
        active && /^[[:space:]]*"digest":[[:space:]]*"/ {
            digest = string_value($0); next
        }
        active && /^[[:space:]]*"browser_download_url":[[:space:]]*"/ {
            url = string_value($0); active = 0
        }
        END {
            if (matches != 1 || digest == "" || url == "") exit 2
            printf "%s\t%s\n", digest, url
        }
    ' "$json_file")" || return 1
    IFS=$'\t' read -r digest url <<<"$record"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    printf '%s\t%s\n' "${digest#sha256:}" "$url"
}

parse_wari_release() {
    local json_file="$1" header wari_record lock_record
    local release_draft release_prerelease
    header="$(awk '
        function string_value(line, value) {
            value = line; sub(/^[^:]*:[[:space:]]*"/, "", value)
            sub(/"[,]*[[:space:]]*$/, "", value); return value
        }
        function scalar_value(line, value) {
            value = line; sub(/^[^:]*:[[:space:]]*/, "", value)
            sub(/[,]*[[:space:]]*$/, "", value); return value
        }
        /^[[:space:]]*"tag_name":/ { tags++; tag = string_value($0) }
        /^[[:space:]]*"draft":/ { drafts++; draft = scalar_value($0) }
        /^[[:space:]]*"prerelease":/ { pres++; pre = scalar_value($0) }
        END {
            if (tags != 1 || drafts != 1 || pres != 1) exit 2
            printf "%s\t%s\t%s\n", tag, draft, pre
        }
    ' "$json_file")" || { die 'invalid Wari release metadata'; return 1; }
    IFS=$'\t' read -r WARI_RELEASE_TAG release_draft release_prerelease <<<"$header"
    [[ "$WARI_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
        "$release_draft" == false && "$release_prerelease" == false ]] || {
        die 'Wari release must be a stable semantic version'; return 1;
    }
    wari_record="$(read_wari_release_asset "$json_file" wari)" || return 1
    lock_record="$(read_wari_release_asset "$json_file" wari.lock)" || return 1
    IFS=$'\t' read -r WARI_ASSET_SHA256 WARI_ASSET_URL <<<"$wari_record"
    IFS=$'\t' read -r WARI_LOCK_ASSET_SHA256 WARI_LOCK_ASSET_URL <<<"$lock_record"
    [[ "$WARI_ASSET_URL" == \
        "https://github.com/wednesdaymoonlab/wari/releases/download/$WARI_RELEASE_TAG/wari" &&
        "$WARI_LOCK_ASSET_URL" == \
        "https://github.com/wednesdaymoonlab/wari/releases/download/$WARI_RELEASE_TAG/wari.lock" ]] || {
        die 'Wari release asset URL is not official'; return 1;
    }
}

fetch_tracked_files() {
    local staging="$1" release_json="$1/wari-release.json"
    download_file \
        "https://api.github.com/repos/wednesdaymoonlab/wari/releases/tags/v$WARI_VERSION" \
        "$release_json" || return 1
    parse_wari_release "$release_json" || return 1
    [[ "$WARI_RELEASE_TAG" == "v$WARI_VERSION" ]] || {
        die 'Wari release tag does not match this initializer'; return 1;
    }
    download_file "$WARI_ASSET_URL" "$staging/wari" 'Wari launcher' || return 1
    verify_checksum sha256 "$WARI_ASSET_SHA256" "$staging/wari" || return 1
    download_file "$WARI_LOCK_ASSET_URL" "$staging/wari.lock" 'Wari lock' || return 1
    verify_checksum sha256 "$WARI_LOCK_ASSET_SHA256" "$staging/wari.lock" || return 1
    rm -f -- "$release_json"
    chmod 755 "$staging/wari"
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
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --yes) assume_yes=1 ;;
            --migrate) migrate=1 ;;
            --help|-h)
                printf '%s\n' 'Usage: install.sh [--yes] [--migrate]' '' \
                    'Add the tracked Wari launcher and lock to the current project.' \
                    'Use --migrate only for a recognized generated Wari 0.1 layout.'
                return 0 ;;
            *) die "unknown initializer option: $1"; return 2 ;;
        esac
        shift
    done
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

    fetch_tracked_files "$staging" || return 1
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
    mv -- "$staging/wari" "$project_root/wari" || return 1; published_wari=1
    mv -- "$staging/wari.lock" "$project_root/wari.lock" || return 1; published_lock=1
    ensure_gitignore_block "$project_root" || return 1
    [[ -z "$legacy_backup" ]] || rm -f -- "$legacy_backup"
    rmdir -- "$staging"
    published_wari=0; published_lock=0
    trap - EXIT INT TERM HUP
    printf '%s\n' 'Wari was added to this project.' '' 'Next:' \
        '  ./wari setup' '' 'Commit these files:' '  wari' '  wari.lock' '  .gitignore'
)

if [[ -z "${BASH_SOURCE[0]-}" || "${BASH_SOURCE[0]-}" == "$0" ]]; then
    initializer_main "$@"
fi
