#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../wari
source "$CORE_DIR/wari"
set +e

SERVICE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-service-test.XXXXXX")"
SERVICE_TMP="$(CDPATH= cd -- "$SERVICE_TMP" && pwd -P)"
SUPERVISORD_TEST_PID=''

cleanup_service_tests() {
    if [[ -n "$SUPERVISORD_TEST_PID" ]] && \
        kill -0 "$SUPERVISORD_TEST_PID" 2>/dev/null; then
        kill "$SUPERVISORD_TEST_PID" 2>/dev/null || true
        wait "$SUPERVISORD_TEST_PID" 2>/dev/null || true
    fi
    rm -rf -- "$SERVICE_TMP"
}
trap cleanup_service_tests EXIT INT TERM

PROJECT="$SERVICE_TMP/Project 100% API"
mkdir -p "$PROJECT"
WARI_PROJECT_ROOT="$PROJECT"
WARI_RUNTIME_DIR="$PROJECT/.wari"

assert_status() {
    local expected="$1"
    local message="$2"
    shift 2
    local actual

    "$@" >/dev/null 2>&1
    actual=$?
    assert_eq "$expected" "$actual" "$message"
}

assert_status 0 'service help succeeds' service_main --help
SERVICE_HELP="$(service_usage 2>/dev/null)"
assert_contains "$SERVICE_HELP" \
    'service generate <systemd|supervisor>' \
    'service help documents supported managers'
assert_contains "$SERVICE_HELP" \
    '--profile=<classic|octane|caddyfile>' \
    'service help documents supported profiles'

assert_status 2 'service requires generate subcommand' service_main
assert_status 2 'service rejects unknown subcommand' service_main inspect
assert_status 2 'service requires manager' service_main generate
assert_status 2 'service rejects unknown manager' \
    service_main generate launchd --profile=classic --user=nobody
assert_status 2 'service requires profile' \
    parse_service_generate_options supervisor --user=nobody
assert_status 2 'service requires user' \
    parse_service_generate_options supervisor --profile=classic
assert_status 2 'service rejects unknown option' \
    parse_service_generate_options supervisor \
    --profile=classic --user=nobody --domain=example.test
assert_status 2 'service rejects duplicate scalar option' \
    parse_service_generate_options supervisor \
    --profile=classic --profile=octane --user=nobody
assert_status 2 'service rejects positional values after manager' \
    parse_service_generate_options supervisor \
    --profile=classic --user=nobody extra

parse_service_generate_options supervisor \
    --profile classic \
    --user nobody \
    --state-dir '/srv/wari state/demo' \
    --stop-timeout 75 \
    --root 'web root' \
    --host ::1 \
    --port 9000
PARSE_STATUS=$?
assert_eq '0' "$PARSE_STATUS" 'service parser accepts split option values'
assert_eq 'supervisor' "${SERVICE_MANAGER-}" 'service parser records manager'
assert_eq 'classic' "${SERVICE_PROFILE-}" 'service parser records profile'
assert_eq 'nobody' "${SERVICE_USER-}" 'service parser records user'
assert_eq '/srv/wari state/demo' "${SERVICE_STATE_DIR-}" \
    'service parser preserves state path spaces'
assert_eq '75' "${SERVICE_STOP_TIMEOUT-}" 'service parser records stop timeout'
assert_eq 'web root' "${SERVICE_ROOT-}" 'service parser records document root'
assert_eq '::1' "${SERVICE_HOST-}" 'service parser records IPv6 loopback'
assert_eq '9000' "${SERVICE_PORT-}" 'service parser records port'

parse_service_generate_options systemd \
    --profile=octane \
    --user=nobody \
    --name=api.service \
    --workers=4 \
    --max-requests=500
assert_eq '0' "$?" 'service parser accepts joined option values'
assert_eq 'api.service' "${SERVICE_NAME-}" 'service parser records explicit name'
assert_eq '127.0.0.1' "${SERVICE_HOST-}" 'service parser defaults host'
assert_eq '8000' "${SERVICE_PORT-}" 'service parser defaults port'
assert_eq '4' "${SERVICE_WORKERS-}" 'service parser records workers'
assert_eq '500' "${SERVICE_MAX_REQUESTS-}" \
    'service parser records max requests'
assert_eq '3600' "${SERVICE_STOP_TIMEOUT-}" \
    'Octane parser defaults conservative stop timeout'

parse_service_generate_options supervisor \
    --profile=caddyfile --user=nobody
assert_eq '0' "$?" 'Caddyfile parser accepts profile defaults'
assert_eq 'Caddyfile' "${SERVICE_CONFIG-}" \
    'Caddyfile parser defaults configuration path'
assert_eq '60' "${SERVICE_STOP_TIMEOUT-}" \
    'Caddyfile parser defaults stop timeout'

derive_service_name
assert_eq '0' "$?" 'service derives a usable project name'
assert_eq 'project-100-api' "${SERVICE_NAME-}" \
    'service name derivation sanitizes the directory basename'
assert_status 2 'service rejects uppercase explicit name' \
    validate_service_name 'API-Service'

assert_status 2 'service rejects root by name' validate_service_user root
assert_status 2 'service rejects missing account' \
    validate_service_user wari-user-that-does-not-exist
if [[ "$(id -u)" -ne 0 ]]; then
    assert_status 0 'service accepts current non-root account' \
        validate_service_user "$(id -un)"
fi
assert_status 2 'service rejects option-like account' \
    validate_service_user '-root'

assert_status 2 'service rejects relative state directory' \
    validate_service_state_dir relative/state
assert_status 2 'service rejects current-directory state component' \
    validate_service_state_dir /var/lib/wari/./escape
assert_status 2 'service rejects parent state component' \
    validate_service_state_dir /var/lib/wari/../escape
assert_status 0 'service accepts absolute state path with spaces' \
    validate_service_state_dir '/srv/wari state/demo%api'

assert_status 2 'service rejects zero port' validate_service_port 0
assert_status 2 'service rejects high port' validate_service_port 65536
assert_status 2 'service rejects nonnumeric port' validate_service_port 8x
assert_status 0 'service accepts minimum port' validate_service_port 1
assert_status 0 'service accepts maximum port' validate_service_port 65535
assert_status 2 'service rejects public IPv4 bind' validate_service_host 0.0.0.0
assert_status 2 'service rejects public IPv6 bind' validate_service_host '::'
assert_status 0 'service accepts IPv4 loopback' validate_service_host 127.0.0.1
assert_status 0 'service accepts IPv6 loopback' validate_service_host '::1'

assert_status 2 'service rejects zero timeout' validate_service_stop_timeout 0
assert_status 2 'service rejects high timeout' \
    validate_service_stop_timeout 86401
assert_status 0 'service accepts minimum timeout' validate_service_stop_timeout 1
assert_status 0 'service accepts maximum timeout' \
    validate_service_stop_timeout 86400
assert_status 2 'service rejects zero workers' validate_service_positive_integer 0 workers
assert_status 0 'service accepts positive workers' \
    validate_service_positive_integer 4 workers

assert_status 2 'service rejects newline injection' \
    validate_service_safe_value $'bad\nvalue' value
assert_status 2 'service rejects carriage-return injection' \
    validate_service_safe_value $'bad\rvalue' value
assert_status 0 'service accepts spaces and percent literals' \
    validate_service_safe_value 'Project 100% API' value

WARI_TEST_PLATFORM_OS=linux
detect_service_platform
assert_eq 'linux' "${PLATFORM_OS-}" 'service platform seam selects Linux'
SERVICE_NAME='api'
SERVICE_STATE_DIR=''
finalize_service_state_paths
assert_eq '0' "$?" 'service finalizes Linux state defaults'
assert_eq '/var/lib/wari/api' "$SERVICE_STATE_DIR" \
    'service defaults Linux state outside the project runtime'
assert_eq '/var/lib/wari/api/config' "${SERVICE_XDG_CONFIG_HOME-}" \
    'service derives XDG config path'
assert_eq '/var/lib/wari/api/data' "${SERVICE_XDG_DATA_HOME-}" \
    'service derives XDG data path'
assert_eq '/var/lib/wari/api/service.log' "${SERVICE_LOG_FILE-}" \
    'service derives Supervisor log path'

if [[ "$(uname -s)" == Darwin && "$(id -u)" -ne 0 ]]; then
    WARI_TEST_PLATFORM_OS=darwin
    detect_service_platform
    SERVICE_USER="$(id -un)"
    SERVICE_NAME='api'
    SERVICE_STATE_DIR=''
    finalize_service_state_paths
    assert_eq '0' "$?" 'service finalizes macOS state defaults'
    assert_eq "$HOME/Library/Application Support/Wari/api" \
        "$SERVICE_STATE_DIR" \
        'service defaults macOS state beneath account home'
fi
unset WARI_TEST_PLATFORM_OS

arguments_dump() {
    local argument
    for argument in "$@"; do
        printf '<%s>\n' "$argument"
    done
}

touch "$PROJECT/wari"
chmod 755 "$PROJECT/wari"
mkdir -p "$PROJECT/public"
printf '<?php\n' >"$PROJECT/public/index.php"

parse_service_generate_options supervisor \
    --profile=classic --user="$(id -un)"
build_service_profile
assert_eq '0' "$?" 'classic profile builds from a front controller'
CLASSIC_START="$(arguments_dump "${SERVICE_START_ARGUMENTS[@]}")"
assert_eq "<$PROJECT/wari>
<frankenphp>
<php-server>
<--listen>
<127.0.0.1:8000>
<--root>
<$PROJECT/public>" "$CLASSIC_START" \
    'classic profile builds the exact foreground command'
assert_eq '0' "${#SERVICE_RELOAD_ARGUMENTS[@]}" \
    'classic profile has no reload command'

MISSING_CLASSIC="$SERVICE_TMP/missing-classic"
mkdir -p "$MISSING_CLASSIC/public"
WARI_PROJECT_ROOT="$MISSING_CLASSIC"
parse_service_generate_options supervisor \
    --profile=classic --user="$(id -un)"
assert_status 1 'classic profile requires public index.php' \
    build_service_profile

WARI_PROJECT_ROOT="$PROJECT"
parse_service_generate_options supervisor \
    --profile=classic --user="$(id -un)" --workers=2
assert_status 2 'classic profile rejects Octane worker option' \
    build_service_profile

mkdir -p "$PROJECT/vendor/laravel/octane"
printf '<?php\n' >"$PROJECT/artisan"
printf '<?php\n' >"$PROJECT/vendor/autoload.php"
printf '{"name":"laravel/octane"}\n' \
    >"$PROJECT/vendor/laravel/octane/composer.json"
printf '{"require":{"laravel/octane":"^2.0"}}\n' >"$PROJECT/composer.json"
printf '<?php\n' >"$PROJECT/public/frankenphp-worker.php"

parse_service_generate_options supervisor \
    --profile=octane --user="$(id -un)" \
    --workers=4 --max-requests=500
build_service_profile
assert_eq '0' "$?" 'Octane profile accepts installed prerequisites'
OCTANE_START="$(arguments_dump "${SERVICE_START_ARGUMENTS[@]}")"
assert_eq "<$PROJECT/wari>
<php>
<artisan>
<octane:start>
<--server=frankenphp>
<--host=127.0.0.1>
<--port=8000>
<--workers=4>
<--max-requests=500>" "$OCTANE_START" \
    'Octane profile builds the exact foreground command'
OCTANE_RELOAD="$(arguments_dump "${SERVICE_RELOAD_ARGUMENTS[@]}")"
assert_eq "<$PROJECT/wari>
<php>
<artisan>
<octane:reload>" "$OCTANE_RELOAD" \
    'Octane profile builds the exact worker reload command'

parse_service_generate_options supervisor \
    --profile=octane --user="$(id -un)"
build_service_profile
OCTANE_DEFAULT_START="$(arguments_dump "${SERVICE_START_ARGUMENTS[@]}")"
if [[ "$OCTANE_DEFAULT_START" == *'--workers'* || \
    "$OCTANE_DEFAULT_START" == *'--max-requests'* ]]; then
    OCTANE_HAS_DEFAULT_FLAGS=1
else
    OCTANE_HAS_DEFAULT_FLAGS=0
fi
assert_eq '0' "$OCTANE_HAS_DEFAULT_FLAGS" \
    'Octane profile omits upstream-managed worker defaults'

MISSING_OCTANE="$SERVICE_TMP/missing-octane"
mkdir -p "$MISSING_OCTANE/public" "$MISSING_OCTANE/vendor/laravel/octane"
touch "$MISSING_OCTANE/wari" "$MISSING_OCTANE/artisan" \
    "$MISSING_OCTANE/vendor/autoload.php" \
    "$MISSING_OCTANE/vendor/laravel/octane/composer.json" \
    "$MISSING_OCTANE/composer.json"
WARI_PROJECT_ROOT="$MISSING_OCTANE"
parse_service_generate_options supervisor \
    --profile=octane --user="$(id -un)"
assert_status 1 'Octane profile requires published FrankenPHP worker' \
    build_service_profile

WARI_PROJECT_ROOT="$PROJECT"
WARI_RUNTIME_DIR="$PROJECT/.wari"
mkdir -p "$WARI_RUNTIME_DIR"
cat >"$WARI_RUNTIME_DIR/frankenphp" <<'FAKE_FRANKENPHP'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_VALIDATE_CAPTURE"
exit "${FAKE_VALIDATE_STATUS:-0}"
FAKE_FRANKENPHP
chmod 755 "$WARI_RUNTIME_DIR/frankenphp"
printf '{ auto_https off }\n:8000 { root * public }\n' >"$PROJECT/Caddyfile"

parse_service_generate_options supervisor \
    --profile=caddyfile --user="$(id -un)"
FAKE_VALIDATE_CAPTURE="$SERVICE_TMP/caddy-validate" build_service_profile
assert_eq '0' "$?" 'Caddyfile profile accepts valid configuration'
CADDY_START="$(arguments_dump "${SERVICE_START_ARGUMENTS[@]}")"
assert_eq "<$PROJECT/wari>
<frankenphp>
<run>
<--config>
<$PROJECT/Caddyfile>" "$CADDY_START" \
    'Caddyfile profile builds the exact foreground command'
CADDY_RELOAD="$(arguments_dump "${SERVICE_RELOAD_ARGUMENTS[@]}")"
assert_eq "<$PROJECT/wari>
<frankenphp>
<reload>
<--config>
<$PROJECT/Caddyfile>" "$CADDY_RELOAD" \
    'Caddyfile profile builds the exact reload command'
CADDY_VALIDATE="$(sed -e 's/^/</' -e 's/$/>/' \
    "$SERVICE_TMP/caddy-validate")"
assert_eq "<validate>
<--config>
<$PROJECT/Caddyfile>" "$CADDY_VALIDATE" \
    'Caddyfile profile validates with the bundled runtime'

parse_service_generate_options supervisor \
    --profile=caddyfile --user="$(id -un)"
FAKE_VALIDATE_CAPTURE="$SERVICE_TMP/caddy-invalid" \
    FAKE_VALIDATE_STATUS=9 build_service_profile >/dev/null 2>&1
INVALID_CADDY_STATUS=$?
assert_eq '1' "$INVALID_CADDY_STATUS" \
    'Caddyfile profile forwards validation failure'

parse_service_generate_options supervisor \
    --profile=caddyfile --user="$(id -un)" --port=9000
assert_status 2 'Caddyfile profile rejects classic port option' \
    build_service_profile

WARI_PROJECT_ROOT="$PROJECT"
WARI_RUNTIME_DIR="$PROJECT/.wari"

TEST_USER="$(id -un)"
WARI_TEST_PLATFORM_OS=linux
service_main generate systemd \
    --profile=classic --user="$TEST_USER" \
    >"$SERVICE_TMP/systemd-classic.out" \
    2>"$SERVICE_TMP/systemd-classic.err"
SYSTEMD_STATUS=$?
SYSTEMD_CLASSIC="$(<"$SERVICE_TMP/systemd-classic.out")"
SYSTEMD_CLASSIC_GUIDE="$(<"$SERVICE_TMP/systemd-classic.err")"
assert_eq '0' "$SYSTEMD_STATUS" 'systemd classic generation succeeds'
assert_contains "$SYSTEMD_CLASSIC" '# Generated by Wari 0.4.2' \
    'systemd output identifies its Wari generator'
assert_contains "$SYSTEMD_CLASSIC" '# Manager: systemd' \
    'systemd output identifies its manager'
assert_contains "$SYSTEMD_CLASSIC" '# Profile: classic' \
    'systemd output identifies its profile'
assert_contains "$SYSTEMD_CLASSIC" '[Unit]' \
    'systemd output contains Unit section'
assert_contains "$SYSTEMD_CLASSIC" 'After=network-online.target' \
    'systemd service waits for network online target'
assert_contains "$SYSTEMD_CLASSIC" '[Service]' \
    'systemd output contains Service section'
assert_contains "$SYSTEMD_CLASSIC" "User=$TEST_USER" \
    'systemd service uses selected account'
assert_contains "$SYSTEMD_CLASSIC" \
    "WorkingDirectory=${PROJECT//%/%%}" \
    'systemd service emits an unquoted absolute working directory'
assert_contains "$SYSTEMD_CLASSIC" \
    'StateDirectory=wari/project-100-api' \
    'systemd service creates default state directory'
assert_contains "$SYSTEMD_CLASSIC" \
    'Environment="XDG_CONFIG_HOME=/var/lib/wari/project-100-api/config"' \
    'systemd service sets Caddy config state'
assert_contains "$SYSTEMD_CLASSIC" 'Restart=always' \
    'systemd service restarts foreground server'
assert_contains "$SYSTEMD_CLASSIC" 'KillMode=control-group' \
    'systemd service terminates the whole process group'
assert_contains "$SYSTEMD_CLASSIC" 'TimeoutStopSec=60' \
    'systemd classic uses default stop timeout'
assert_contains "$SYSTEMD_CLASSIC" 'StandardOutput=journal' \
    'systemd service logs to journal'
assert_contains "$SYSTEMD_CLASSIC" 'WantedBy=multi-user.target' \
    'systemd service can start at boot'
if [[ "$SYSTEMD_CLASSIC" == *'ExecReload='* ]]; then
    SYSTEMD_CLASSIC_HAS_RELOAD=1
else
    SYSTEMD_CLASSIC_HAS_RELOAD=0
fi
assert_eq '0' "$SYSTEMD_CLASSIC_HAS_RELOAD" \
    'systemd classic omits unsupported reload command'
assert_contains "$SYSTEMD_CLASSIC_GUIDE" \
    '=== Wari installation guide ===' \
    'systemd guide has a visible heading'
assert_contains "$SYSTEMD_CLASSIC_GUIDE" \
    'This section is not part of the generated configuration.' \
    'systemd guide distinguishes itself from configuration'
assert_contains "$SYSTEMD_CLASSIC_GUIDE" \
    '/etc/systemd/system/project-100-api.service' \
    'systemd guide identifies installation path'
assert_contains "$SYSTEMD_CLASSIC_GUIDE" 'systemctl enable --now' \
    'systemd guide explains enable and start'
assert_contains "$SYSTEMD_CLASSIC_GUIDE" 'journalctl -u project-100-api.service' \
    'systemd guide explains journal access'

service_main generate systemd \
    --profile=octane --user="$TEST_USER" --name=api \
    --workers=4 --max-requests=500 \
    >"$SERVICE_TMP/systemd-octane.out" \
    2>"$SERVICE_TMP/systemd-octane.err"
SYSTEMD_OCTANE="$(<"$SERVICE_TMP/systemd-octane.out")"
assert_contains "$SYSTEMD_OCTANE" \
    'ExecStart=' \
    'systemd Octane emits foreground command'
assert_contains "$SYSTEMD_OCTANE" \
    'octane:start' \
    'systemd Octane starts Octane server'
assert_contains "$SYSTEMD_OCTANE" \
    '--workers=4' \
    'systemd Octane forwards worker count'
assert_contains "$SYSTEMD_OCTANE" \
    'ExecReload=' \
    'systemd Octane emits worker reload command'
assert_contains "$SYSTEMD_OCTANE" 'octane:reload' \
    'systemd Octane reload invokes Artisan'
assert_contains "$SYSTEMD_OCTANE" 'TimeoutStopSec=3600' \
    'systemd Octane uses conservative stop timeout'
assert_contains "$(<"$SERVICE_TMP/systemd-octane.err")" \
    'systemctl reload api.service' \
    'systemd Octane guide explains reload'

FAKE_VALIDATE_CAPTURE="$SERVICE_TMP/systemd-caddy-validate" \
service_main generate systemd \
    --profile=caddyfile --user="$TEST_USER" --name=caddy \
    >"$SERVICE_TMP/systemd-caddy.out" \
    2>"$SERVICE_TMP/systemd-caddy.err"
assert_contains "$(<"$SERVICE_TMP/systemd-caddy.out")" \
    'frankenphp" "reload" "--config"' \
    'systemd Caddyfile emits Caddy reload arguments'

WARI_TEST_PLATFORM_OS=darwin
service_main generate supervisor \
    --profile=classic --user="$TEST_USER" --name=api \
    --state-dir='/srv/wari state/demo%api' \
    >"$SERVICE_TMP/supervisor-classic.out" \
    2>"$SERVICE_TMP/supervisor-classic.err"
SUPERVISOR_STATUS=$?
SUPERVISOR_CLASSIC="$(<"$SERVICE_TMP/supervisor-classic.out")"
SUPERVISOR_GUIDE="$(<"$SERVICE_TMP/supervisor-classic.err")"
assert_eq '0' "$SUPERVISOR_STATUS" 'Supervisor classic generation succeeds'
assert_contains "$SUPERVISOR_CLASSIC" '# Generated by Wari 0.4.2' \
    'Supervisor output identifies its Wari generator'
assert_contains "$SUPERVISOR_CLASSIC" '# Manager: supervisor' \
    'Supervisor output identifies its manager'
assert_contains "$SUPERVISOR_CLASSIC" '# Profile: classic' \
    'Supervisor output identifies its profile'
assert_contains "$SUPERVISOR_CLASSIC" '[program:api]' \
    'Supervisor output contains program section'
assert_contains "$SUPERVISOR_CLASSIC" 'process_name=%(program_name)s' \
    'Supervisor output preserves native interpolation'
assert_contains "$SUPERVISOR_CLASSIC" "user=$TEST_USER" \
    'Supervisor service uses selected account'
assert_contains "$SUPERVISOR_CLASSIC" 'autostart=true' \
    'Supervisor service starts automatically'
assert_contains "$SUPERVISOR_CLASSIC" 'autorestart=true' \
    'Supervisor service restarts foreground server'
assert_contains "$SUPERVISOR_CLASSIC" 'stopasgroup=true' \
    'Supervisor service stops the process group'
assert_contains "$SUPERVISOR_CLASSIC" 'killasgroup=true' \
    'Supervisor service kills a timed-out process group'
assert_contains "$SUPERVISOR_CLASSIC" 'stopwaitsecs=60' \
    'Supervisor classic uses default stop timeout'
assert_contains "$SUPERVISOR_CLASSIC" \
    'XDG_CONFIG_HOME="/srv/wari state/demo%%api/config"' \
    'Supervisor environment escapes percent interpolation'
assert_contains "$SUPERVISOR_CLASSIC" \
    'stdout_logfile=/srv/wari state/demo%%api/service.log' \
    'Supervisor logs beneath external state directory'
assert_contains "$SUPERVISOR_GUIDE" 'supervisorctl -c /absolute/path/supervisord.conf reread' \
    'Supervisor guide requires an explicit parent config'
assert_contains "$SUPERVISOR_GUIDE" \
    '=== Wari installation guide ===' \
    'Supervisor guide has a visible heading'
assert_contains "$SUPERVISOR_GUIDE" \
    'This section is not part of the generated configuration.' \
    'Supervisor guide distinguishes itself from configuration'
assert_contains "$SUPERVISOR_GUIDE" \
    'supervisord.conf restart api' \
    'Supervisor classic guide uses service restart'

WARI_TEST_PLATFORM_OS=linux
service_main generate supervisor \
    --profile=octane --user="$TEST_USER" --name=api \
    >"$SERVICE_TMP/supervisor-octane.out" \
    2>"$SERVICE_TMP/supervisor-octane.err"
assert_contains "$(<"$SERVICE_TMP/supervisor-octane.out")" \
    'octane:start' \
    'Supervisor Octane starts Octane server'
assert_contains "$(<"$SERVICE_TMP/supervisor-octane.err")" \
    'octane:reload' \
    'Supervisor Octane guide gives worker reload command'
assert_contains "$(<"$SERVICE_TMP/supervisor-octane.err")" \
    '/etc/supervisor/conf.d/api.conf' \
    'Supervisor Linux guide labels common include path'

FAKE_VALIDATE_CAPTURE="$SERVICE_TMP/supervisor-caddy-validate" \
service_main generate supervisor \
    --profile=caddyfile --user="$TEST_USER" --name=caddy \
    >"$SERVICE_TMP/supervisor-caddy.out" \
    2>"$SERVICE_TMP/supervisor-caddy.err"
if [[ "$(<"$SERVICE_TMP/supervisor-caddy.out")" == *'frankenphp reload'* ]]; then
    SUPERVISOR_CADDY_CONFIG_CLEAN=0
else
    SUPERVISOR_CADDY_CONFIG_CLEAN=1
fi
assert_eq '1' "${SUPERVISOR_CADDY_CONFIG_CLEAN:-0}" \
    'Supervisor Caddyfile guide does not leak into config'
assert_contains "$(<"$SERVICE_TMP/supervisor-caddy.err")" \
    'frankenphp reload' \
    'Supervisor Caddyfile guide gives reload command'

if [[ "$(uname -s)" == Linux ]] && \
    command -v systemd-analyze >/dev/null 2>&1; then
    cp "$SERVICE_TMP/systemd-classic.out" \
        "$SERVICE_TMP/wari-test.service"
    systemd-analyze verify "$SERVICE_TMP/wari-test.service" \
        >"$SERVICE_TMP/systemd-native.out" 2>&1
    SYSTEMD_NATIVE_STATUS=$?
    if [[ "$SYSTEMD_NATIVE_STATUS" -ne 0 ]]; then
        sed 's/^/# systemd-analyze: /' "$SERVICE_TMP/systemd-native.out"
    fi
    assert_eq '0' "$SYSTEMD_NATIVE_STATUS" \
        'systemd-analyze accepts generated service syntax'
else
    printf '%s\n' '# systemd-analyze native check skipped (tool or Linux unavailable)'
fi

if command -v supervisord >/dev/null 2>&1 && \
    command -v supervisorctl >/dev/null 2>&1; then
    mkdir -p "$SERVICE_TMP/supervisor-child-logs"
    sed 's/^autostart=true$/autostart=false/' \
        "$SERVICE_TMP/supervisor-classic.out" \
        >"$SERVICE_TMP/native-program.conf"
    cat >"$SERVICE_TMP/supervisord.conf" <<EOF
[unix_http_server]
file=$SERVICE_TMP/supervisor.sock

[supervisord]
logfile=$SERVICE_TMP/supervisord.log
pidfile=$SERVICE_TMP/supervisord.pid
childlogdir=$SERVICE_TMP/supervisor-child-logs
nodaemon=true

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$SERVICE_TMP/supervisor.sock

[include]
files=$SERVICE_TMP/native-program.conf
EOF
    supervisord -n -c "$SERVICE_TMP/supervisord.conf" \
        >"$SERVICE_TMP/supervisord-native.out" 2>&1 &
    SUPERVISORD_TEST_PID=$!
    SUPERVISOR_SOCKET_READY=0
    SUPERVISOR_POLL=0
    while [[ "$SUPERVISOR_POLL" -lt 100 ]]; do
        if [[ -S "$SERVICE_TMP/supervisor.sock" ]]; then
            SUPERVISOR_SOCKET_READY=1
            break
        fi
        if ! kill -0 "$SUPERVISORD_TEST_PID" 2>/dev/null; then
            break
        fi
        SUPERVISOR_POLL=$((SUPERVISOR_POLL + 1))
        sleep 0.05
    done
    if [[ "$SUPERVISOR_SOCKET_READY" -eq 1 ]]; then
        supervisorctl -c "$SERVICE_TMP/supervisord.conf" shutdown \
            >>"$SERVICE_TMP/supervisord-native.out" 2>&1
        SUPERVISOR_NATIVE_STATUS=$?
    else
        SUPERVISOR_NATIVE_STATUS=1
    fi
    wait "$SUPERVISORD_TEST_PID" 2>/dev/null
    SUPERVISOR_WAIT_STATUS=$?
    SUPERVISORD_TEST_PID=''
    if [[ "$SUPERVISOR_NATIVE_STATUS" -eq 0 && \
        "$SUPERVISOR_WAIT_STATUS" -eq 0 ]]; then
        SUPERVISOR_NATIVE_RESULT=0
    else
        SUPERVISOR_NATIVE_RESULT=1
        sed 's/^/# supervisord: /' "$SERVICE_TMP/supervisord-native.out"
    fi
    assert_eq '0' "$SUPERVISOR_NATIVE_RESULT" \
        'supervisord accepts generated program syntax'
else
    printf '%s\n' '# supervisord native check skipped (tools unavailable)'
fi

service_main generate supervisor \
    --profile=classic --user=root \
    >"$SERVICE_TMP/invalid.out" 2>"$SERVICE_TMP/invalid.err"
INVALID_SERVICE_STATUS=$?
assert_eq '2' "$INVALID_SERVICE_STATUS" \
    'service generation rejects root account'
assert_eq '' "$(<"$SERVICE_TMP/invalid.out")" \
    'service generation errors leave stdout empty'

render_service_instructions() {
    printf '%s\n' 'installation must not be shown'
    return 29
}
service_main generate supervisor \
    --profile=classic --user="$TEST_USER" \
    >"$SERVICE_TMP/late-failure.out" \
    2>"$SERVICE_TMP/late-failure.err"
LATE_FAILURE_STATUS=$?
assert_eq '29' "$LATE_FAILURE_STATUS" \
    'late instruction rendering failure is forwarded'
assert_eq '' "$(<"$SERVICE_TMP/late-failure.out")" \
    'late service rendering failure leaves stdout empty'
assert_eq '' "$(<"$SERVICE_TMP/late-failure.err")" \
    'late service rendering failure prints no success instructions'
unset WARI_TEST_PLATFORM_OS

finish_tests
