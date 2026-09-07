#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"

if [[ ! -f "$CORE_DIR/install.sh" ]]; then
    fail 'install.sh exists'
    finish_tests
    exit $?
fi

# shellcheck source=../install.sh
source "$CORE_DIR/install.sh"

PIPE_HELP_OUTPUT="$(bash -s -- --help <"$CORE_DIR/install.sh")"
assert_contains "$PIPE_HELP_OUTPUT" 'Usage: install.sh [options]' 'runs main when installer arrives on standard input'

reset_args() {
    ASSUME_YES=0
    REQUESTED_VERSION=latest
    LINUX_BUILD=static
    SHOW_HELP=0
    VERSION_OPTION_SET=0
    LINUX_BUILD_OPTION_SET=0
}

assert_eq 'v1.12.7' "$(normalize_version 1.12.7)" 'adds v prefix'
assert_eq 'v1.12.7' "$(normalize_version v1.12.7)" 'keeps v prefix'
assert_fails 'rejects shell input in version' normalize_version '1.2.3;touch bad'
assert_fails 'rejects incomplete version' normalize_version '1.12'

reset_args
parse_args --yes --version 1.12.7 --linux-build gnu
assert_eq '1' "$ASSUME_YES" 'parses --yes'
assert_eq 'v1.12.7' "$REQUESTED_VERSION" 'parses and normalizes --version'
assert_eq 'gnu' "$LINUX_BUILD" 'parses --linux-build'
assert_eq '1' "${VERSION_OPTION_SET-0}" 'marks explicit version option'
assert_eq '1' "${LINUX_BUILD_OPTION_SET-0}" 'marks explicit Linux build option'

reset_args
parse_args --help
assert_eq '1' "$SHOW_HELP" 'parses --help'

assert_fails 'rejects unknown option' parse_args --wat
assert_fails 'rejects missing version value' parse_args --version
assert_fails 'rejects invalid Linux build' parse_args --linux-build dynamic

detect_platform Linux x86_64 static
assert_eq 'linux' "$PLATFORM_OS" 'normalizes Linux OS'
assert_eq 'x86_64' "$PLATFORM_ARCH" 'normalizes Linux x86 architecture'
assert_eq 'frankenphp-linux-x86_64' "$ASSET_NAME" 'maps Linux x86 static'

detect_platform Linux amd64 gnu
assert_eq 'frankenphp-linux-x86_64-gnu' "$ASSET_NAME" 'maps Linux amd64 GNU'

detect_platform Linux aarch64 static
assert_eq 'arm64' "$PLATFORM_ARCH" 'normalizes Linux aarch64'
assert_eq 'frankenphp-linux-aarch64' "$ASSET_NAME" 'maps Linux ARM static'

detect_platform Linux arm64 gnu
assert_eq 'frankenphp-linux-aarch64-gnu' "$ASSET_NAME" 'maps Linux arm64 GNU'

detect_platform Darwin arm64 static
assert_eq 'darwin' "$PLATFORM_OS" 'normalizes macOS'
assert_eq 'frankenphp-mac-arm64' "$ASSET_NAME" 'maps Apple Silicon'

detect_platform Darwin x86_64 static
assert_eq 'frankenphp-mac-x86_64' "$ASSET_NAME" 'maps macOS Intel'

assert_fails 'rejects GNU choice on macOS' detect_platform Darwin arm64 gnu
assert_fails 'rejects Windows' detect_platform MINGW64_NT-10.0 x86_64 static
assert_fails 'rejects RISC-V' detect_platform Linux riscv64 static

if ! declare -F parse_release >/dev/null 2>&1; then
    fail 'release metadata functions exist'
    finish_tests
    exit $?
fi

FIXTURE="$TEST_DIR/fixtures/frankenphp-release.json"
parse_release "$FIXTURE" 'frankenphp-linux-x86_64'
assert_eq 'v1.12.7' "$RESOLVED_TAG" 'reads release tag'
assert_eq '1111111111111111111111111111111111111111111111111111111111111111' "$ASSET_SHA256" 'selects exact asset digest'
assert_eq 'https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64' "$ASSET_URL" 'selects exact asset URL'

METADATA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-metadata-test.XXXXXX")"
trap 'rm -rf -- "$METADATA_TMP"' EXIT

sed 's/"draft": false/"draft": true/' "$FIXTURE" >"$METADATA_TMP/draft.json"
assert_fails 'rejects draft release' parse_release "$METADATA_TMP/draft.json" 'frankenphp-linux-x86_64'

sed 's/"prerelease": false/"prerelease": true/' "$FIXTURE" >"$METADATA_TMP/prerelease.json"
assert_fails 'rejects prerelease' parse_release "$METADATA_TMP/prerelease.json" 'frankenphp-linux-x86_64'

sed 's/sha256:111111/sha512:111111/' "$FIXTURE" >"$METADATA_TMP/sha512.json"
assert_fails 'rejects non-SHA-256 asset digest' parse_release "$METADATA_TMP/sha512.json" 'frankenphp-linux-x86_64'

sed 's#https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64"#https://evil.example/frankenphp-linux-x86_64"#' "$FIXTURE" >"$METADATA_TMP/evil-url.json"
assert_fails 'rejects download URL on another host' parse_release "$METADATA_TMP/evil-url.json" 'frankenphp-linux-x86_64'

sed 's/"frankenphp-linux-x86_64-debug"/"frankenphp-linux-x86_64"/' "$FIXTURE" >"$METADATA_TMP/duplicate.json"
assert_fails 'rejects duplicate exact asset names' parse_release "$METADATA_TMP/duplicate.json" 'frankenphp-linux-x86_64'

assert_fails 'rejects missing asset' parse_release "$FIXTURE" 'frankenphp-linux-riscv64'

printf 'abc' >"$METADATA_TMP/checksum.txt"
assert_eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' "$(calculate_checksum sha256 "$METADATA_TMP/checksum.txt")" 'calculates SHA-256'
assert_eq 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7' "$(calculate_checksum sha384 "$METADATA_TMP/checksum.txt")" 'calculates SHA-384'
verify_checksum sha256 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' "$METADATA_TMP/checksum.txt"
assert_fails 'rejects checksum mismatch' verify_checksum sha256 'aa7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' "$METADATA_TMP/checksum.txt"

test_download_retries_transport_errors() (
    local calls="$METADATA_TMP/curl-calls"
    local destination="$METADATA_TMP/retried-download"
    printf '0' >"$calls"
    sleep() { :; }
    curl() {
        local count
        local output=''
        local previous=''
        count="$(<"$calls")"
        count=$((count + 1))
        printf '%s' "$count" >"$calls"
        for argument in "$@"; do
            if [[ "$previous" == '-o' ]]; then output="$argument"; fi
            previous="$argument"
        done
        if [[ "$count" -lt 3 ]]; then return 56; fi
        printf 'downloaded' >"$output"
    }
    download_file 'https://getcomposer.org/installer' "$destination" || return 1
    [[ "$(<"$calls")" == '3' && "$(<"$destination")" == 'downloaded' ]]
)
RETRY_LOG="$METADATA_TMP/retry.log"
assert_eq '0' "$(test_download_retries_transport_errors 2>"$RETRY_LOG"; printf '%s' "$?")" 'retries transport errors before succeeding'
assert_contains "$(<"$RETRY_LOG")" 'Download failed (attempt 1/4)' 'reports retry attempts'

test_download_progress_modes() (
    local destination="$METADATA_TMP/progress-download"
    local args_file="$METADATA_TMP/progress-args"
    local log_file="$METADATA_TMP/progress.log"
    local terminal_args terminal_log quiet_args quiet_log

    curl() {
        local argument
        local previous=''
        : >"$args_file"
        for argument in "$@"; do
            printf '%s\n' "$argument" >>"$args_file"
            if [[ "$previous" == '-o' ]]; then
                printf 'downloaded' >"$argument"
            fi
            previous="$argument"
        done
    }

    can_show_download_progress() { return 0; }
    download_file 'https://getcomposer.org/installer' "$destination" 'Composer' 2>"$log_file" || return 1
    terminal_args="$(<"$args_file")"
    terminal_log="$(<"$log_file")"

    can_show_download_progress() { return 1; }
    download_file 'https://getcomposer.org/installer' "$destination" 'Composer' 2>"$log_file" || return 1
    quiet_args="$(<"$args_file")"
    quiet_log="$(<"$log_file")"

    [[ "$terminal_args" == *'--progress-bar'* ]] || return 2
    [[ "$terminal_args" != *'--silent'* ]] || return 3
    [[ "$terminal_log" == *'Downloading Composer'* ]] || return 4
    [[ "$quiet_args" == *'--silent'* ]] || return 5
    [[ "$quiet_args" != *'--progress-bar'* ]] || return 6
    [[ "$quiet_log" != *'Downloading Composer'* ]] || return 7
)
assert_eq '0' "$(test_download_progress_modes; printf '%s' "$?")" 'selects progress or quiet download output based on terminal availability'

if ! declare -F prompt_choice >/dev/null 2>&1; then
    fail 'interactive and staging functions exist'
    finish_tests
    exit $?
fi

printf '\n' >"$METADATA_TMP/prompt-default.in"
exec 3<"$METADATA_TMP/prompt-default.in" 4>"$METADATA_TMP/prompt-default.out"
assert_eq '1' "$(prompt_choice 'Choose' 1 1 2)" 'blank prompt input selects default'
exec 3<&- 4>&-

printf 'invalid\n2\n' >"$METADATA_TMP/prompt-repeat.in"
exec 3<"$METADATA_TMP/prompt-repeat.in" 4>"$METADATA_TMP/prompt-repeat.out"
assert_eq '2' "$(prompt_choice 'Choose' 1 1 2)" 'prompt accepts a valid retry'
exec 3<&- 4>&-
assert_contains "$(<"$METADATA_TMP/prompt-repeat.out")" 'Please enter 1 or 2.' 'prompt explains valid choices'

test_explicit_options_skip_prompts() (
    PROJECT_ROOT="$METADATA_TMP/explicit-options"
    PLATFORM_OS='linux'
    PLATFORM_ARCH='x86_64'
    REQUESTED_VERSION='v1.12.7'
    LINUX_BUILD='gnu'
    VERSION_OPTION_SET=1
    LINUX_BUILD_OPTION_SET=1
    exec 3</dev/null 4>"$METADATA_TMP/explicit-options.out"
    collect_interactive_choices || return 1
    [[ "$REQUESTED_VERSION" == 'v1.12.7' && "$LINUX_BUILD" == 'gnu' ]]
)
assert_eq '0' "$(test_explicit_options_skip_prompts; printf '%s' "$?")" 'explicit flags take precedence over interactive prompts'
assert_contains "$(<"$METADATA_TMP/explicit-options.out")" "Runtime:      $METADATA_TMP/explicit-options/.wari" 'interactive summary shows hidden runtime destination'
assert_contains "$(<"$METADATA_TMP/explicit-options.out")" "Command:      $METADATA_TMP/explicit-options/wari" 'interactive summary shows dispatcher destination'

printf '\n' >"$METADATA_TMP/confirm-default.in"
exec 3<"$METADATA_TMP/confirm-default.in" 4>"$METADATA_TMP/confirm-default.out"
confirm_install
assert_eq '0' "$?" 'blank confirmation accepts default'
exec 3<&- 4>&-

printf 'n\n' >"$METADATA_TMP/confirm-no.in"
exec 3<"$METADATA_TMP/confirm-no.in" 4>"$METADATA_TMP/confirm-no.out"
assert_fails 'confirmation rejects n' confirm_install
exec 3<&- 4>&-

SAFE_PROJECT="$METADATA_TMP/project"
mkdir -p "$SAFE_PROJECT"
assert_eq '0' "$(is_safe_staging_path "$SAFE_PROJECT" "$SAFE_PROJECT/.wari-install.ABC123"; printf '%s' "$?")" 'accepts direct staging child'
assert_fails 'rejects project root as staging' is_safe_staging_path "$SAFE_PROJECT" "$SAFE_PROJECT"
assert_fails 'rejects final wari path as staging' is_safe_staging_path "$SAFE_PROJECT" "$SAFE_PROJECT/wari"
assert_fails 'rejects empty staging suffix' is_safe_staging_path "$SAFE_PROJECT" "$SAFE_PROJECT/.wari-install."
assert_fails 'rejects staging path in another directory' is_safe_staging_path "$SAFE_PROJECT" "$METADATA_TMP/.wari-install.ABC123"

PROJECT_ROOT="$SAFE_PROJECT"
create_staging "$PROJECT_ROOT"
assert_eq "$PROJECT_ROOT" "$(dirname -- "$STAGING_DIR")" 'creates staging directly under project'
assert_contains "$(basename -- "$STAGING_DIR")" '.wari-install.' 'uses staging prefix'
cleanup
assert_eq '0' "$(if [[ ! -e "$STAGING_DIR" ]]; then printf 0; else printf 1; fi)" 'cleanup removes safe staging directory'

PREFLIGHT_EMPTY="$METADATA_TMP/preflight-empty"
mkdir -p "$PREFLIGHT_EMPTY"
assert_eq '0' "$(preflight_project "$PREFLIGHT_EMPTY"; printf '%s' "$?")" 'accepts project without Wari paths'

PREFLIGHT_WARI_FILE="$METADATA_TMP/preflight-wari-file"
mkdir -p "$PREFLIGHT_WARI_FILE"
printf 'user file' >"$PREFLIGHT_WARI_FILE/wari"
assert_fails 'rejects an existing wari file' preflight_project "$PREFLIGHT_WARI_FILE"

PREFLIGHT_WARI_LINK="$METADATA_TMP/preflight-wari-link"
mkdir -p "$PREFLIGHT_WARI_LINK"
ln -s missing-target "$PREFLIGHT_WARI_LINK/wari"
assert_eq '0' "$(if [[ -L "$PREFLIGHT_WARI_LINK/wari" && ! -e "$PREFLIGHT_WARI_LINK/wari" ]]; then printf 0; else printf 1; fi)" 'creates a broken wari link fixture'
assert_fails 'rejects a broken wari symbolic link' preflight_project "$PREFLIGHT_WARI_LINK"

PREFLIGHT_RUNTIME_DIR="$METADATA_TMP/preflight-runtime-dir"
mkdir -p "$PREFLIGHT_RUNTIME_DIR/.wari"
assert_fails 'rejects an existing hidden runtime directory' preflight_project "$PREFLIGHT_RUNTIME_DIR"

PREFLIGHT_RUNTIME_LINK="$METADATA_TMP/preflight-runtime-link"
mkdir -p "$PREFLIGHT_RUNTIME_LINK"
ln -s missing-target "$PREFLIGHT_RUNTIME_LINK/.wari"
assert_eq '0' "$(if [[ -L "$PREFLIGHT_RUNTIME_LINK/.wari" && ! -e "$PREFLIGHT_RUNTIME_LINK/.wari" ]]; then printf 0; else printf 1; fi)" 'creates a broken hidden runtime link fixture'
assert_fails 'rejects a broken hidden runtime symbolic link' preflight_project "$PREFLIGHT_RUNTIME_LINK"

if ! declare -F install_frankenphp >/dev/null 2>&1; then
    fail 'artifact installation functions exist'
    finish_tests
    exit $?
fi

test_frankenphp_install_success() (
    local project="$METADATA_TMP/franken-success"
    local progress_label=''
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    create_staging "$project"
    ASSET_URL='https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64'
    ASSET_SHA256='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    download_file() { progress_label="${3-}"; printf 'abc' >"$2"; }
    install_frankenphp "$STAGING_DIR"
    [[ -x "$STAGING_DIR/runtime/frankenphp" &&
        ! -e "$STAGING_DIR/runtime/frankenphp.download" &&
        "$progress_label" == 'FrankenPHP v1.12.7' ]]
)
assert_eq '0' "$(test_frankenphp_install_success; printf '%s' "$?")" 'installs verified FrankenPHP with a versioned progress label'

test_frankenphp_download_failure() (
    local project="$METADATA_TMP/franken-download-failure"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    create_staging "$project"
    ASSET_URL='https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64'
    ASSET_SHA256='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    download_file() { return 1; }
    install_frankenphp "$STAGING_DIR"
)
assert_fails 'propagates FrankenPHP download failure' test_frankenphp_download_failure

test_frankenphp_checksum_failure() (
    local project="$METADATA_TMP/franken-checksum-failure"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    create_staging "$project"
    ASSET_URL='https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64'
    ASSET_SHA256='aa7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    download_file() { printf 'abc' >"$2"; }
    install_frankenphp "$STAGING_DIR"
)
assert_fails 'rejects downloaded FrankenPHP with wrong checksum' test_frankenphp_checksum_failure

write_fake_frankenphp() {
    local destination="$1"
    mkdir -p "$(dirname -- "$destination")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -eu'
        printf '%s\n' 'shift'
        printf '%s\n' 'shift'
        printf '%s\n' "install_dir=''"
        printf '%s\n' 'for argument in "$@"; do'
        printf '%s\n' '  case "$argument" in --install-dir=*) install_dir="${argument#--install-dir=}" ;; esac'
        printf '%s\n' 'done'
        printf '%s\n' '[[ -n "$install_dir" ]]'
        printf '%s\n' 'printf '\''fake composer'\'' >"$install_dir/composer.phar"'
    } >"$destination"
    chmod 755 "$destination"
}

test_composer_install_success() (
    local project="$METADATA_TMP/composer-success"
    local progress_label=''
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    create_staging "$project"
    write_fake_frankenphp "$STAGING_DIR/runtime/frankenphp"
    download_file() {
        case "$1" in
            https://getcomposer.org/installer) progress_label="${3-}"; printf 'abc' >"$2" ;;
            https://composer.github.io/installer.sig) printf '%s\n' 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7' >"$2" ;;
            *) return 1 ;;
        esac
    }
    install_composer "$STAGING_DIR"
    [[ -f "$STAGING_DIR/runtime/composer.phar" &&
        ! -e "$STAGING_DIR/composer-setup.php" &&
        "$progress_label" == 'Composer' ]]
)
assert_eq '0' "$(test_composer_install_success; printf '%s' "$?")" 'installs Composer with a progress label after verifier passes'

test_composer_checksum_failure() (
    local project="$METADATA_TMP/composer-checksum-failure"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    create_staging "$project"
    write_fake_frankenphp "$STAGING_DIR/runtime/frankenphp"
    download_file() {
        case "$1" in
            https://getcomposer.org/installer) printf 'tampered' >"$2" ;;
            https://composer.github.io/installer.sig) printf '%s\n' 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7' >"$2" ;;
            *) return 1 ;;
        esac
    }
    install_composer "$STAGING_DIR"
)
assert_fails 'rejects tampered Composer installer' test_composer_checksum_failure

if ! declare -F write_manifest >/dev/null 2>&1; then
    fail 'manifest and main-flow functions exist'
    finish_tests
    exit $?
fi

ESCAPED_JSON="$(json_escape $'quote" slash\\ tab\t return\r newline\n')"
assert_eq 'quote\" slash\\ tab\t return\r newline\n' "$ESCAPED_JSON" 'escapes JSON control characters'

write_fake_version_runtime() {
    local destination="$1"
    mkdir -p "$(dirname -- "$destination")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -u'
        printf '%s\n' 'if [[ "${1-}" == php-cli ]]; then'
        printf '%s\n' '  shift'
        printf '%s\n' '  case "${1-}" in'
        printf '%s\n' '    *php-proxy.php)'
        printf '%s\n' '      case "${2-}" in version) printf '\''PHP 8.5.3 (cli)\n'\'' ;; *) exit 0 ;; esac'
        printf '%s\n' '      ;;'
        printf '%s\n' '    *composer.phar) printf '\''Composer version 2.8.12 2025-04-08 13:03:14\n'\'' ;;'
        printf '%s\n' '    *) exit 0 ;;'
        printf '%s\n' '  esac'
        printf '%s\n' 'elif [[ "${1-}" == version ]]; then'
        printf '%s\n' '  printf '\''FrankenPHP v1.12.7 PHP 8.5.3 Caddy v2.10.2\n'\'''
        printf '%s\n' 'else'
        printf '%s\n' '  exit 0'
        printf '%s\n' 'fi'
    } >"$destination"
    chmod 755 "$destination"
}

MANIFEST_PROJECT="$METADATA_TMP/manifest-project"
MANIFEST_WARI="$MANIFEST_PROJECT/wari"
mkdir -p "$MANIFEST_WARI/runtime"
write_fake_version_runtime "$MANIFEST_WARI/runtime/frankenphp"
printf 'fake composer' >"$MANIFEST_WARI/runtime/composer.phar"
generate_wrappers "$MANIFEST_WARI"
PLATFORM_OS='darwin'
PLATFORM_ARCH='arm64'
LINUX_BUILD='static'
RESOLVED_TAG='v1.12.7'
ASSET_NAME='frankenphp-mac-arm64'
ASSET_URL='https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-mac-arm64'
ASSET_SHA256='5555555555555555555555555555555555555555555555555555555555555555'
detect_installed_versions "$MANIFEST_WARI"
write_manifest "$MANIFEST_WARI"
MANIFEST_CONTENT="$(<"$MANIFEST_WARI/manifest.json")"
assert_contains "$MANIFEST_CONTENT" '"wari_version": "0.1.0"' 'manifest records Wari version'
assert_contains "$MANIFEST_CONTENT" '"frankenphp_version": "v1.12.7"' 'manifest records FrankenPHP version'
assert_contains "$MANIFEST_CONTENT" '"php_version": "8.5.3"' 'manifest records PHP version'
assert_contains "$MANIFEST_CONTENT" '"composer_version": "2.8.12"' 'manifest records Composer version'
assert_contains "$MANIFEST_CONTENT" '"linux_build": null' 'manifest uses null Linux build on macOS'
assert_contains "$MANIFEST_CONTENT" '"checksum_verified": true' 'manifest records checksum verification'
assert_contains "$MANIFEST_CONTENT" '"slsa_verified": false' 'manifest distinguishes SLSA status'

PUBLIC_SMOKE_PROJECT="$METADATA_TMP/public-smoke"
mkdir -p "$PUBLIC_SMOKE_PROJECT/.wari"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '%s\n' 'printf "%s" "${1-}" >>"$WARI_PUBLIC_CAPTURE"'
    printf '%s\n' 'shift || true'
    printf '%s\n' 'for argument in "$@"; do printf "|%s" "$argument" >>"$WARI_PUBLIC_CAPTURE"; done'
    printf '%s\n' 'printf "\n" >>"$WARI_PUBLIC_CAPTURE"'
} >"$PUBLIC_SMOKE_PROJECT/wari"
chmod 755 "$PUBLIC_SMOKE_PROJECT/wari"
PUBLIC_SMOKE_CAPTURE="$METADATA_TMP/public-smoke.capture"
: >"$PUBLIC_SMOKE_CAPTURE"
assert_eq '0' "$(WARI_PUBLIC_CAPTURE="$PUBLIC_SMOKE_CAPTURE" run_public_smoke_checks "$PUBLIC_SMOKE_PROJECT"; printf '%s' "$?")" 'public smoke checks run through root dispatcher'
PUBLIC_SMOKE_CONTENT="$(<"$PUBLIC_SMOKE_CAPTURE")"
assert_contains "$PUBLIC_SMOKE_CONTENT" 'php|--version' 'public smoke checks PHP version'
assert_contains "$PUBLIC_SMOKE_CONTENT" 'composer|--version' 'public smoke checks Composer version'
assert_contains "$PUBLIC_SMOKE_CONTENT" 'create-project|--help' 'public smoke checks create-project help'
assert_contains "$PUBLIC_SMOKE_CONTENT" 'frankenphp|version' 'public smoke checks FrankenPHP version'
assert_contains "$PUBLIC_SMOKE_CONTENT" "php|-r|" 'public smoke checks manifest through PHP'
assert_contains "$PUBLIC_SMOKE_CONTENT" "$PUBLIC_SMOKE_PROJECT/.wari/manifest.json" 'public smoke checks hidden manifest path'

test_main_public_smoke_failure_cleanup() (
    local project="$METADATA_TMP/main-public-smoke-failure"
    local status
    mkdir -p "$project"
    uname() {
        case "$1" in -s) printf 'Linux\n' ;; -m) printf 'x86_64\n' ;; esac
    }
    fetch_release_json() { cat "$FIXTURE"; }
    install_frankenphp() { write_fake_version_runtime "$1/runtime/frankenphp"; }
    install_composer() { printf 'fake composer' >"$1/runtime/composer.phar"; }
    run_public_smoke_checks() { return 19; }
    (
        cd "$project"
        main --yes --version 1.12.7 --linux-build static
    ) >/dev/null 2>&1
    status=$?
    [[ "$status" -eq 19 ]] || return 1
    [[ ! -e "$project/.wari" && ! -L "$project/.wari" ]] || return 2
    [[ ! -e "$project/wari" && ! -L "$project/wari" ]] || return 3
    [[ -z "$(find "$project" -maxdepth 1 -name '.wari-install.*' -print -quit)" ]]
)
assert_eq '0' "$(test_main_public_smoke_failure_cleanup; printf '%s' "$?")" 'public smoke failure rolls back both published paths'

test_main_success() (
    local project="$METADATA_TMP/main-success"
    mkdir -p "$project"
    cd "$project"
    uname() {
        case "$1" in -s) printf 'Linux\n' ;; -m) printf 'x86_64\n' ;; esac
    }
    fetch_release_json() { cat "$FIXTURE"; }
    install_frankenphp() { write_fake_version_runtime "$1/runtime/frankenphp"; }
    install_composer() { printf 'fake composer' >"$1/runtime/composer.phar"; }
    main --yes --version 1.12.7 --linux-build static >"$project/install-output" || return 1
    [[ -x "$project/wari" && ! -d "$project/wari" ]] || return 2
    [[ -x "$project/.wari/php" && -x "$project/.wari/composer" &&
        -x "$project/.wari/create-project" ]] || return 3
    [[ -x "$project/.wari/serve" && -x "$project/.wari/frankenphp" ]] || return 4
    [[ -f "$project/.wari/manifest.json" ]] || return 5
    [[ -x "$project/.wari/runtime/frankenphp" && -f "$project/.wari/runtime/composer.phar" ]] || return 6
    [[ ! -e "$project/.wari/wari" && ! -L "$project/.wari/wari" ]] || return 7
    [[ "$(<"$project/install-output")" == *'./wari php --version'* ]] || return 8
    [[ "$(<"$project/install-output")" == *'./wari composer --version'* ]] || return 9
    [[ "$(<"$project/install-output")" == *'./wari serve'* ]] || return 10
    [[ -z "$(find "$project" -maxdepth 1 -name '.wari-install.*' -print -quit)" ]]
)
assert_eq '0' "$(test_main_success >/dev/null; printf '%s' "$?")" 'main publishes hidden runtime and root dispatcher'

test_publish_install_success() (
    local project="$METADATA_TMP/publish-success"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    STAGING_DIR=''
    PUBLISHED_RUNTIME=0
    PUBLISHED_DISPATCHER=0
    create_staging "$project"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$STAGING_DIR/wari"
    chmod 755 "$STAGING_DIR/wari"
    publish_install "$STAGING_DIR" "$project" || return 1
    [[ -d "$project/.wari" && -x "$project/wari" && -x "$project/.wari/wari" ]] || return 2
    [[ "$project/wari" -ef "$project/.wari/wari" ]]
)
assert_eq '0' "$(test_publish_install_success; printf '%s' "$?")" 'publishes runtime and ownership-verifiable dispatcher link'

test_publish_runtime_rename_failure_cleanup() (
    local project="$METADATA_TMP/publish-mv-failure"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    STAGING_DIR=''
    PUBLISHED_RUNTIME=0
    PUBLISHED_DISPATCHER=0
    create_staging "$project"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$STAGING_DIR/wari"
    chmod 755 "$STAGING_DIR/wari"
    mv() { return 55; }
    publish_install "$STAGING_DIR" "$project" && return 1
    cleanup || return 1
    [[ ! -e "$project/.wari" && ! -e "$project/wari" ]]
    [[ -z "$(find "$project" -maxdepth 1 -name '.wari-install.*' -print -quit)" ]]
)
assert_eq '0' "$(test_publish_runtime_rename_failure_cleanup 2>/dev/null; printf '%s' "$?")" 'cleans staging after runtime publication failure'

test_publish_dispatcher_collision_cleanup() (
    local project="$METADATA_TMP/publish-link-collision"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    STAGING_DIR=''
    PUBLISHED_RUNTIME=0
    PUBLISHED_DISPATCHER=0
    create_staging "$project"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$STAGING_DIR/wari"
    chmod 755 "$STAGING_DIR/wari"
    ln() { printf 'concurrent user file' >"$2"; return 1; }
    publish_install "$STAGING_DIR" "$project" && return 1
    cleanup || return 1
    [[ ! -e "$project/.wari" ]]
    [[ -f "$project/wari" && "$(<"$project/wari")" == 'concurrent user file' ]]
    [[ -z "$(find "$project" -maxdepth 1 -name '.wari-install.*' -print -quit)" ]]
)
assert_eq '0' "$(test_publish_dispatcher_collision_cleanup 2>/dev/null; printf '%s' "$?")" 'preserves concurrent dispatcher while cleaning published runtime'

test_cleanup_preserves_replaced_dispatcher() (
    local project="$METADATA_TMP/publish-replaced-dispatcher"
    mkdir -p "$project"
    PROJECT_ROOT="$project"
    STAGING_DIR=''
    PUBLISHED_RUNTIME=0
    PUBLISHED_DISPATCHER=0
    create_staging "$project"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$STAGING_DIR/wari"
    chmod 755 "$STAGING_DIR/wari"
    publish_install "$STAGING_DIR" "$project" || return 1
    rm -f -- "$project/wari"
    printf 'replacement user file' >"$project/wari"
    cleanup || return 2
    [[ ! -e "$project/.wari" ]] || return 3
    [[ -f "$project/wari" && "$(<"$project/wari")" == 'replacement user file' ]]
)
assert_eq '0' "$(test_cleanup_preserves_replaced_dispatcher; printf '%s' "$?")" 'cleanup preserves dispatcher replaced after publication'

test_existing_wari_stops_before_fetch() (
    local project="$METADATA_TMP/main-existing"
    mkdir -p "$project/wari"
    cd "$project"
    fetch_release_json() { touch "$project/network-called"; }
    main --yes
)
assert_fails 'main rejects existing wari' test_existing_wari_stops_before_fetch
assert_eq '0' "$(if [[ ! -e "$METADATA_TMP/main-existing/network-called" ]]; then printf 0; else printf 1; fi)" 'existing wari stops before network access'

finish_tests
