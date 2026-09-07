#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"

SETUP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-setup-test.XXXXXX")"
SETUP_TMP="$(CDPATH= cd -- "$SETUP_TMP" && pwd -P)"
trap 'rm -rf -- "$SETUP_TMP"' EXIT

if ! declare -F install_locked_frankenphp >/dev/null 2>&1 ||
    ! declare -F install_locked_composer >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'locked artifact installers exist'
    finish_tests
    exit $?
fi

checksum_of() {
    calculate_checksum "$1" "$2"
}

test_locked_artifact_install() (
    STAGING="$SETUP_TMP/staging"
    CAPTURE="$SETUP_TMP/composer-arguments"
    mkdir -p "$STAGING/runtime"

    LOCK_FRANKENPHP_VERSION='1.12.7'
    LOCK_COMPOSER_VERSION='2.8.11'
    PLATFORM_OS='linux'
    PLATFORM_ARCH='x86_64'
    LOCK_LINUX_BUILD='static'
    ASSET_NAME='frankenphp-linux-x86_64'
    ASSET_SHA256="$(printf 'frankenphp-binary' | shasum -a 256 | sed 's/[[:space:]].*//')"

    download_file() {
        case "$1" in
            https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64)
                cat >"$2" <<'FAKE_FRANKENPHP'
#!/usr/bin/env bash
set -u
if [[ "${1-}" == 'php-cli' && "${2-}" == *composer-setup.php ]]; then
    shift 2
    printf '%s\n' "$@" >"$WARI_COMPOSER_CAPTURE"
    install_dir=''
    for argument in "$@"; do
        case "$argument" in --install-dir=*) install_dir="${argument#--install-dir=}" ;; esac
    done
    printf 'composer-phar' >"$install_dir/composer.phar"
    exit 0
fi
if [[ "${1-}" == 'php-cli' && "${2-}" == *composer.phar && "${3-}" == '--version' ]]; then
    printf 'Composer version 2.8.11 2025-01-01\n'
    exit 0
fi
exit 1
FAKE_FRANKENPHP
                ;;
            https://getcomposer.org/installer)
                printf 'composer-installer' >"$2"
                ;;
            *) return 88 ;;
        esac
    }

    # Use the checksum of the complete fake executable written by download_file.
    download_file \
        'https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64' \
        "$SETUP_TMP/frankenphp-reference"
    LOCK_FRANKENPHP_LINUX_X86_64_SHA256="$(checksum_of sha256 "$SETUP_TMP/frankenphp-reference")"
    ASSET_SHA256="$LOCK_FRANKENPHP_LINUX_X86_64_SHA256"
    LOCK_COMPOSER_INSTALLER_SHA384="$(printf 'composer-installer' >"$SETUP_TMP/installer-reference"; checksum_of sha384 "$SETUP_TMP/installer-reference")"
    LOCK_COMPOSER_SHA256="$(printf 'composer-phar' >"$SETUP_TMP/phar-reference"; checksum_of sha256 "$SETUP_TMP/phar-reference")"

    install_locked_frankenphp "$STAGING" || return 1
    WARI_COMPOSER_CAPTURE="$CAPTURE" install_locked_composer "$STAGING" || return 2
    [[ -x "$STAGING/runtime/frankenphp" ]] || return 3
    [[ -f "$STAGING/runtime/composer.phar" ]] || return 4
    [[ "$(<"$CAPTURE")" == *'--version=2.8.11'* ]] || return 5
    [[ "$(<"$CAPTURE")" == *"--install-dir=$STAGING/runtime"* ]] || return 6
)

assert_eq '0' "$(test_locked_artifact_install; printf '%s' "$?")" \
    'installs exact locked FrankenPHP and Composer artifacts'

test_bad_composer_installer() (
    STAGING="$SETUP_TMP/bad-installer"
    mkdir -p "$STAGING/runtime"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STAGING/runtime/frankenphp"
    chmod 755 "$STAGING/runtime/frankenphp"
    LOCK_COMPOSER_INSTALLER_SHA384="$(printf '%096d' 0)"
    LOCK_COMPOSER_VERSION='2.8.11'
    LOCK_COMPOSER_SHA256="$(printf '%064d' 0)"
    download_file() { printf 'changed-installer' >"$2"; }
    install_locked_composer "$STAGING"
)

assert_fails 'rejects a Composer installer that differs from the lock' \
    test_bad_composer_installer

if declare -F write_manifest >/dev/null 2>&1 &&
    declare -F run_staged_smoke_checks >/dev/null 2>&1; then
    MANIFEST_STAGING="$SETUP_TMP/manifest"
    mkdir -p "$MANIFEST_STAGING/runtime"
    LOCK_SHA256="$(printf '%064d' 6)"
    LOCK_WARI_VERSION='0.2.1'
    LOCK_FRANKENPHP_VERSION='1.12.7'
    LOCK_COMPOSER_VERSION='2.8.11'
    LOCK_LINUX_BUILD='static'
    PLATFORM_OS='linux'
    PLATFORM_ARCH='x86_64'
    ASSET_NAME='frankenphp-linux-x86_64'
    ASSET_SHA256="$(printf '%064d' 7)"
    INSTALLED_PHP_VERSION='8.4.0'
    INSTALLED_FRANKENPHP_VERSION='1.12.7'
    INSTALLED_COMPOSER_VERSION='2.8.11'
    write_manifest "$MANIFEST_STAGING"
    MANIFEST_CONTENT="$(<"$MANIFEST_STAGING/manifest.json")"
    assert_contains "$MANIFEST_CONTENT" '"layout_version": 2' \
        'manifest records the tracked-launcher layout'
    assert_contains "$MANIFEST_CONTENT" "\"lock_sha256\": \"$LOCK_SHA256\"" \
        'manifest binds the runtime to the complete lock'
    assert_contains "$MANIFEST_CONTENT" '"composer_version": "2.8.11"' \
        'manifest records the exact Composer version'
    assert_eq 'Wari runtime layout 2' "$(<"$MANIFEST_STAGING/.wari-owned")" \
        'staged runtime contains the exact ownership marker'
    for command_name in php composer create-project frankenphp; do
        printf '#!/usr/bin/env bash\nexit 0\n' >"$MANIFEST_STAGING/$command_name"
        chmod 755 "$MANIFEST_STAGING/$command_name"
    done
    assert_eq '0' "$(run_staged_smoke_checks "$MANIFEST_STAGING"; printf '%s' "$?")" \
        'staged smoke checks accept a complete healthy runtime'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'manifest writer and staged smoke checks exist'
fi

if declare -F setup_main >/dev/null 2>&1; then
    make_setup_project() {
        local project="$1"
        mkdir -p "$project"
        cp "$CORE_DIR/wari" "$project/wari"
        cp "$CORE_DIR/wari.lock" "$project/wari.lock"
        chmod 755 "$project/wari"
    }

    install_fake_runtime() {
        local staging="$1"
        mkdir -p "$staging/runtime"
        cat >"$staging/runtime/frankenphp" <<'FAKE_BINARY'
#!/usr/bin/env bash
exit 0
FAKE_BINARY
        chmod 755 "$staging/runtime/frankenphp"
    }

    install_fake_composer() {
        printf 'fake composer' >"$1/runtime/composer.phar"
    }

    generate_fake_wrappers() {
        local staging="$1"
        local command_name
        for command_name in php composer create-project serve frankenphp; do
            cat >"$staging/$command_name" <<'FAKE_WRAPPER'
#!/usr/bin/env bash
case "$(basename -- "$0")/${1-}" in
    php/--version) printf 'PHP 8.4.0 (cli)\n' ;;
    composer/--version) printf 'Composer version 2.8.11 2025-01-01\n' ;;
    frankenphp/version) printf 'FrankenPHP v1.12.7\n' ;;
esac
exit 0
FAKE_WRAPPER
            chmod 755 "$staging/$command_name"
        done
    }

    INITIAL_PROJECT="$SETUP_TMP/initial project"
    make_setup_project "$INITIAL_PROJECT"
    (
        WARI_PROJECT_ROOT="$INITIAL_PROJECT"
        WARI_RUNTIME_DIR="$INITIAL_PROJECT/.wari"
        install_locked_frankenphp() { install_fake_runtime "$1"; }
        install_locked_composer() { install_fake_composer "$1"; }
        generate_wrappers() { generate_fake_wrappers "$1"; }
        setup_main --yes
    )
    INITIAL_STATUS=$?
    assert_eq '0' "$INITIAL_STATUS" 'explicit setup installs the initial runtime'
    assert_eq '0' "$(validate_runtime "$INITIAL_PROJECT"; printf '%s' "$?")" \
        'initial setup publishes a runtime matching the lock'

    NOOP_MARKER="$SETUP_TMP/noop-installer-called"
    (
        WARI_PROJECT_ROOT="$INITIAL_PROJECT"
        WARI_RUNTIME_DIR="$INITIAL_PROJECT/.wari"
        install_locked_frankenphp() { : >"$NOOP_MARKER"; return 91; }
        setup_main --yes
    )
    assert_eq '0' "$?" 'matching setup is idempotent'
    assert_eq '0' "$(test ! -e "$NOOP_MARKER"; printf '%s' "$?")" \
        'matching setup performs no download or reinstall'

    FOREIGN_SETUP_PROJECT="$SETUP_TMP/foreign-setup"
    make_setup_project "$FOREIGN_SETUP_PROJECT"
    mkdir "$FOREIGN_SETUP_PROJECT/.wari"
    printf 'keep me' >"$FOREIGN_SETUP_PROJECT/.wari/user-data"
    assert_fails 'setup refuses an unrecognized runtime' \
        env WARI_PROJECT_ROOT="$FOREIGN_SETUP_PROJECT" \
        WARI_RUNTIME_DIR="$FOREIGN_SETUP_PROJECT/.wari" bash -c \
        'source "$1/wari"; setup_main --yes' _ "$FOREIGN_SETUP_PROJECT"
    assert_eq 'keep me' "$(<"$FOREIGN_SETUP_PROJECT/.wari/user-data")" \
        'setup preserves data in an unrecognized runtime'

    DECEPTIVE_PROJECT="$SETUP_TMP/deceptive-runtime"
    make_setup_project "$DECEPTIVE_PROJECT"
    mkdir "$DECEPTIVE_PROJECT/.wari"
    printf '%s\n' '{"layout_version": 2}' >"$DECEPTIVE_PROJECT/.wari/manifest.json"
    printf 'keep deceptive data' >"$DECEPTIVE_PROJECT/.wari/user-data"
    assert_fails 'setup rejects a layout-version-only runtime' \
        env WARI_PROJECT_ROOT="$DECEPTIVE_PROJECT" \
        WARI_RUNTIME_DIR="$DECEPTIVE_PROJECT/.wari" bash -c \
        'source "$1/wari"; setup_main --yes' _ "$DECEPTIVE_PROJECT"
    assert_eq 'keep deceptive data' "$(<"$DECEPTIVE_PROJECT/.wari/user-data")" \
        'setup never replaces a runtime without its ownership marker'

    LOCKED_PROJECT="$SETUP_TMP/locked"
    make_setup_project "$LOCKED_PROJECT"
    mkdir "$LOCKED_PROJECT/.wari-setup.lock"
    assert_fails 'setup rejects an active setup lock' \
        env WARI_PROJECT_ROOT="$LOCKED_PROJECT" \
        WARI_RUNTIME_DIR="$LOCKED_PROJECT/.wari" bash -c \
        'source "$1/wari"; setup_main --yes' _ "$LOCKED_PROJECT"

    ROLLBACK_PROJECT="$SETUP_TMP/rollback"
    cp -R "$INITIAL_PROJECT" "$ROLLBACK_PROJECT"
    printf 'original runtime' >"$ROLLBACK_PROJECT/.wari/original-marker"
    set +e
    (
        WARI_PROJECT_ROOT="$ROLLBACK_PROJECT"
        WARI_RUNTIME_DIR="$ROLLBACK_PROJECT/.wari"
        validate_runtime() { return 1; }
        install_locked_frankenphp() { install_fake_runtime "$1"; }
        install_locked_composer() { install_fake_composer "$1"; }
        generate_wrappers() { generate_fake_wrappers "$1"; }
        setup_main --yes
    ) >/dev/null 2>&1
    ROLLBACK_STATUS=$?
    set -e
    assert_eq '1' "$ROLLBACK_STATUS" 'public validation failure fails setup'
    assert_eq 'original runtime' "$(<"$ROLLBACK_PROJECT/.wari/original-marker")" \
        'public validation failure restores the previous runtime'
    assert_eq '' "$(find "$ROLLBACK_PROJECT" -maxdepth 1 \
        \( -name '.wari-install.*' -o -name '.wari-backup.*' -o \
        -name '.wari-setup.lock' \) -print -quit)" \
        'failed replacement removes owned setup state'

    INITIAL_ROLLBACK_PROJECT="$SETUP_TMP/initial-rollback"
    make_setup_project "$INITIAL_ROLLBACK_PROJECT"
    set +e
    (
        WARI_PROJECT_ROOT="$INITIAL_ROLLBACK_PROJECT"
        WARI_RUNTIME_DIR="$INITIAL_ROLLBACK_PROJECT/.wari"
        validate_runtime() { return 1; }
        install_locked_frankenphp() { install_fake_runtime "$1"; }
        install_locked_composer() { install_fake_composer "$1"; }
        generate_wrappers() { generate_fake_wrappers "$1"; }
        setup_main --yes
    ) >/dev/null 2>&1
    INITIAL_ROLLBACK_STATUS=$?
    set -e
    assert_eq '1' "$INITIAL_ROLLBACK_STATUS" \
        'initial public validation failure fails setup'
    assert_eq '0' "$(test ! -e "$INITIAL_ROLLBACK_PROJECT/.wari"; printf '%s' "$?")" \
        'initial public validation failure removes the published runtime'
    assert_eq '' "$(find "$INITIAL_ROLLBACK_PROJECT" -maxdepth 1 \
        \( -name '.wari-install.*' -o -name '.wari-backup.*' -o \
        -name '.wari-setup.lock' \) -print -quit)" \
        'failed initial setup removes owned setup state'

    MKTEMP_PROJECT="$SETUP_TMP/mktemp-failure"
    make_setup_project "$MKTEMP_PROJECT"
    set +e
    (
        WARI_PROJECT_ROOT="$MKTEMP_PROJECT"
        WARI_RUNTIME_DIR="$MKTEMP_PROJECT/.wari"
        mktemp() { return 73; }
        setup_main --yes
    ) >/dev/null 2>&1
    MKTEMP_STATUS=$?
    set -e
    assert_eq '73' "$MKTEMP_STATUS" 'staging creation failure is propagated'
    assert_eq '0' "$(test ! -e "$MKTEMP_PROJECT/.wari-setup.lock"; printf '%s' "$?")" \
        'staging creation failure releases the owned setup lock'

    EARLY_SIGNAL_PROJECT="$SETUP_TMP/early-signal"
    make_setup_project "$EARLY_SIGNAL_PROJECT"
    set +e
    (
        WARI_PROJECT_ROOT="$EARLY_SIGNAL_PROJECT"
        WARI_RUNTIME_DIR="$EARLY_SIGNAL_PROJECT/.wari"
        mkdir() {
            command mkdir "$@" || return
            sh -c 'kill -TERM "$PPID"'
        }
        mktemp() { return 73; }
        setup_main --yes
    ) >/dev/null 2>&1
    EARLY_SIGNAL_STATUS=$?
    set -e
    assert_eq '73' "$EARLY_SIGNAL_STATUS" \
        'signal in the lock-acquisition window cannot strand setup'
    assert_eq '0' "$(test ! -e "$EARLY_SIGNAL_PROJECT/.wari-setup.lock"; printf '%s' "$?")" \
        'early setup signal leaves no owned lock'

    GNU_PROJECT="$SETUP_TMP/gnu-on-musl"
    make_setup_project "$GNU_PROJECT"
    sed 's/^linux_build=static$/linux_build=gnu/' \
        "$GNU_PROJECT/wari.lock" >"$GNU_PROJECT/wari.lock.next"
    mv "$GNU_PROJECT/wari.lock.next" "$GNU_PROJECT/wari.lock"
    GNU_DOWNLOAD_MARKER="$SETUP_TMP/gnu-download-called"
    set +e
    (
        WARI_PROJECT_ROOT="$GNU_PROJECT"
        WARI_RUNTIME_DIR="$GNU_PROJECT/.wari"
        detect_current_platform() { PLATFORM_OS='linux'; PLATFORM_ARCH='x86_64'; }
        has_glibc() { return 1; }
        install_locked_frankenphp() { : >"$GNU_DOWNLOAD_MARKER"; }
        setup_main --yes
    ) >/dev/null 2>&1
    GNU_STATUS=$?
    set -e
    assert_eq '1' "$GNU_STATUS" 'GNU setup rejects a host without glibc'
    assert_eq '0' "$(test ! -e "$GNU_DOWNLOAD_MARKER"; printf '%s' "$?")" \
        'GNU compatibility failure happens before download'

    DECLINE_PROJECT="$SETUP_TMP/decline"
    make_setup_project "$DECLINE_PROJECT"
    set +e
    (
        WARI_PROJECT_ROOT="$DECLINE_PROJECT"
        WARI_RUNTIME_DIR="$DECLINE_PROJECT/.wari"
        confirm_setup() { return 1; }
        setup_main
    ) >/dev/null 2>&1
    DECLINE_STATUS=$?
    set -e
    assert_eq '0' "$DECLINE_STATUS" 'declining setup is a successful no-op'
    assert_eq '0' "$(test ! -e "$DECLINE_PROJECT/.wari"; printf '%s' "$?")" \
        'declining setup creates no runtime'

    NONINTERACTIVE_PROJECT="$SETUP_TMP/noninteractive"
    make_setup_project "$NONINTERACTIVE_PROJECT"
    set +e
    NONINTERACTIVE_OUTPUT="$(WARI_PROJECT_ROOT="$NONINTERACTIVE_PROJECT" \
        WARI_RUNTIME_DIR="$NONINTERACTIVE_PROJECT/.wari" \
        setup_main </dev/null 2>&1)"
    NONINTERACTIVE_STATUS=$?
    set -e
    assert_eq '1' "$NONINTERACTIVE_STATUS" \
        'non-interactive setup requires an explicit automation flag'
    assert_contains "$NONINTERACTIVE_OUTPUT" '--yes' \
        'non-interactive setup explains the automation flag'
else
    TESTS_RUN=$((TESTS_RUN + 1))
    fail 'explicit setup command exists'
fi

finish_tests
