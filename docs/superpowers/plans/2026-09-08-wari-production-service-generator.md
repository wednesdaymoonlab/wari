# Wari Production Service Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe `wari service generate` command that emits complete systemd or Supervisor configuration for classic FrankenPHP, Laravel Octane, and project Caddyfile production services on Linux and macOS.

**Architecture:** Parse CLI values into validated Bash globals, build one manager-neutral service model whose commands remain argument arrays, then render that model with separate systemd and Supervisor serializers. Route every server launch through the generated `.wari/frankenphp` wrapper so development fallbacks and generated production XDG state share one environment boundary.

**Tech Stack:** Bash 3.2-compatible shell, FrankenPHP/Caddy CLI, Laravel Octane CLI, systemd unit syntax, Supervisor program configuration, the repository's TAP-like shell test helpers, and GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-08-wari-production-service-generator-design.md`

## Global Constraints

- Never run `git add`, `git commit`, or `git push`; leave every change unstaged for user review.
- The generator targets Linux x86_64/ARM64 and macOS Intel/Apple Silicon already supported by Wari.
- systemd generation is Linux-only; Supervisor generation supports Linux and macOS; launchd is out of scope.
- `service generate` writes only a complete configuration to stdout and writes instructions/diagnostics to stderr.
- No generation error may leave partial configuration on stdout.
- The generator never writes service files, invokes `sudo`, edits service-manager configuration, or starts/stops services.
- `--profile` and a non-root, existing `--user` are required; framework auto-detection is forbidden.
- Classic and Octane profiles bind only to `127.0.0.1` or `::1`.
- Production XDG state stays outside `.wari/`; no command invents or overwrites `HOME`.
- Commands are built as argument arrays and escaped by the target renderer; generated services do not invoke a shell.
- Bash code must remain compatible with macOS Bash 3.2: no associative arrays, namerefs, `mapfile`, or Bash 4-only case conversion.
- Do not mark a manager/profile combination production verified until its live service lifecycle test has passed on the documented target.

## File map

- Modify `wari`: public dispatch, service parser/model/profile builders, manager renderers, installation instructions, common FrankenPHP environment wrapper, and version.
- Modify `install.sh`: release version synchronized with the launcher.
- Modify `wari.lock`: regenerated launcher digest and release version after implementation stabilizes.
- Create `tests/test-service.sh`: parser, validation, profiles, renderers, output-channel, escaping, and instruction tests.
- Modify `tests/test-wrappers.sh`: common XDG wrapper regression coverage.
- Modify `tests/test-launcher.sh`, `tests/test-installer.sh`, `tests/test-lock.sh`, `tests/test-setup.sh`, `tests/test-update.sh`, `tests/test-create-project.sh`, and `tests/test-initializer.sh`: version/runtime fixtures and public dispatch expectations.
- Modify `.github/workflows/test.yml`: execute service-generator tests on all offline platforms and conditional native syntax verification where tools exist.
- Modify `README.md`: public command summary and production boundary.
- Create `docs/production/README.md`: supported production workflow and responsibility boundary.
- Create `docs/production/profiles.md`: classic, Octane, and Caddyfile selection and lifecycle.
- Create `docs/production/systemd.md`: generation, installation, journald, reload/restart, update, and removal.
- Create `docs/production/supervisor.md`: Linux/macOS state setup, includes, logs, reload/restart, update, and removal.
- Modify `docs/compatibility/README.md` and relevant framework pages only to record newly observed results; do not promote unexecuted checks.

---

### Task 1: Centralize FrankenPHP environment handling

**Files:**
- Modify: `wari` in `generate_wrappers`
- Test: `tests/test-wrappers.sh`
- Modify: `README.md` only if its existing HOME/XDG wording needs correction after the code change

**Interfaces:**
- Consumes: generated wrapper directory layout (`.wari/frankenphp`, `.wari/php`, `.wari/serve`, `.wari/runtime/frankenphp`).
- Produces: `.wari/frankenphp` as the only wrapper that executes the raw FrankenPHP binary; it preserves explicit XDG values and supplies project-local fallbacks only when `HOME` and the corresponding XDG variable are absent.

- [ ] **Step 1: Add failing common-wrapper tests**

Extend the fake FrankenPHP capture in `tests/test-wrappers.sh` and add assertions equivalent to:

```bash
(
    unset HOME XDG_CONFIG_HOME XDG_DATA_HOME
    FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" version
)
RAW_NO_HOME_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_NO_HOME_CAPTURE" \
    "xdg_config_home=$WARI/runtime/xdg/config" \
    'FrankenPHP wrapper supplies local XDG config without HOME'
assert_contains "$RAW_NO_HOME_CAPTURE" \
    "xdg_data_home=$WARI/runtime/xdg/data" \
    'FrankenPHP wrapper supplies local XDG data without HOME'

(
    unset HOME
    XDG_CONFIG_HOME='/srv/state/config' \
    XDG_DATA_HOME='/srv/state/data' \
    FAKE_CAPTURE="$CAPTURE" "$WARI/frankenphp" version
)
RAW_EXPLICIT_XDG_CAPTURE="$(<"$CAPTURE")"
assert_contains "$RAW_EXPLICIT_XDG_CAPTURE" \
    'xdg_config_home=/srv/state/config' \
    'FrankenPHP wrapper preserves explicit XDG config'
assert_contains "$RAW_EXPLICIT_XDG_CAPTURE" \
    'xdg_data_home=/srv/state/data' \
    'FrankenPHP wrapper preserves explicit XDG data'
```

Also unset HOME for `serve` and `php -S`, then assert both reach the same
fallback values through `.wari/frankenphp`. Add a test with a non-empty HOME and
unset XDG variables that asserts neither XDG variable is synthesized.

- [ ] **Step 2: Run the wrapper test and confirm RED**

Run:

```bash
bash tests/test-wrappers.sh
```

Expected: the direct FrankenPHP and `serve` XDG assertions fail because those
wrappers currently execute `.wari/runtime/frankenphp` directly.

- [ ] **Step 3: Move fallback logic to the common wrapper**

Change generated `.wari/frankenphp` to contain this behavior before its final
`exec`:

```bash
if [[ -z "${HOME:-}" ]]; then
    if [[ -z "${XDG_CONFIG_HOME:-}" ]]; then
        XDG_CONFIG_HOME="$WARI_DIR/runtime/xdg/config"
        export XDG_CONFIG_HOME
        mkdir -p -- "$XDG_CONFIG_HOME"
    fi
    if [[ -z "${XDG_DATA_HOME:-}" ]]; then
        XDG_DATA_HOME="$WARI_DIR/runtime/xdg/data"
        export XDG_DATA_HOME
        mkdir -p -- "$XDG_DATA_HOME"
    fi
fi

exec "$WARI_DIR/runtime/frankenphp" "$@"
```

Change `.wari/serve` to execute:

```bash
exec "$WARI_DIR/frankenphp" php-server \
    --listen 127.0.0.1:8000 \
    --root "$PROJECT_ROOT/public"
```

Change the `php -S` translation to execute `$WARI_DIR/frankenphp` and remove its
duplicate inline XDG block. All non-server PHP CLI paths continue to execute
the raw binary as before.

- [ ] **Step 4: Verify the common environment boundary**

Run:

```bash
bash tests/test-wrappers.sh
```

Expected: all wrapper tests pass, including explicit-XDG preservation and the
existing argument/cwd tests.

- [ ] **Step 5: Inspect the focused diff**

Run:

```bash
git diff -- wari tests/test-wrappers.sh README.md
```

Expected: only the common wrapper boundary, its tests, and any necessary
wording correction appear. Leave changes unstaged.

---

### Task 2: Parse and normalize the service command

**Files:**
- Modify: `wari` before `launcher_usage`
- Create: `tests/test-service.sh`

**Interfaces:**
- Consumes: `service_main "$@"`, existing `die`, `detect_current_platform`, `validate_runtime`, and `WARI_PROJECT_ROOT`.
- Produces: `service_usage`, `reset_service_state`, `parse_service_generate_options`, `derive_service_name`, `validate_service_common_options`, and normalized `SERVICE_*` globals used by all later tasks.

- [ ] **Step 1: Create the service test harness and parser failures**

Create `tests/test-service.sh` with the repository's standard prologue:

```bash
#!/usr/bin/env bash
set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/test-helper.sh"
source "$CORE_DIR/wari"

SERVICE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-service-test.XXXXXX")"
SERVICE_TMP="$(CDPATH= cd -- "$SERVICE_TMP" && pwd -P)"
trap 'rm -rf -- "$SERVICE_TMP"' EXIT
```

Use a fixture project whose basename contains spaces and set
`WARI_PROJECT_ROOT` to its physical path. Stub only the expensive runtime check
in parser tests. Add assertions for:

```bash
assert_fails 'service requires generate subcommand' service_main
assert_fails 'service rejects unknown subcommand' service_main inspect
assert_fails 'service requires manager' service_main generate
assert_fails 'service rejects unknown manager' service_main generate launchd \
    --profile=classic --user=nobody
assert_fails 'service requires profile' service_main generate supervisor \
    --user=nobody
assert_fails 'service requires user' service_main generate supervisor \
    --profile=classic
assert_fails 'service rejects unknown option' service_main generate supervisor \
    --profile=classic --user=nobody --domain=example.test
assert_fails 'service rejects duplicate scalar option' service_main generate supervisor \
    --profile=classic --profile=octane --user=nobody
```

Call `parse_service_generate_options` directly for successful cases and assert
the exact normalized manager, profile, default/explicit service name, host,
port, state-dir override, and profile-specific option globals.

- [ ] **Step 2: Run the new test and confirm RED**

Run:

```bash
bash tests/test-service.sh
```

Expected: FAIL because `service_main` and parser functions do not exist.

- [ ] **Step 3: Implement the Bash 3.2-compatible parser**

Add a reset function with explicit scalar globals and seen flags:

```bash
reset_service_state() {
    SERVICE_MANAGER=''
    SERVICE_PROFILE=''
    SERVICE_USER=''
    SERVICE_NAME=''
    SERVICE_STATE_DIR=''
    SERVICE_STOP_TIMEOUT=''
    SERVICE_ROOT=''
    SERVICE_HOST=''
    SERVICE_PORT=''
    SERVICE_WORKERS=''
    SERVICE_MAX_REQUESTS=''
    SERVICE_CONFIG=''
    SERVICE_START_ARGUMENTS=()
    SERVICE_RELOAD_ARGUMENTS=()
}
```

Implement `service_usage` with the exact public syntax from the spec. Parse
both `--key=value` and `--key value` forms, reject duplicate scalar options,
and reject positional values after the manager. Use a `case` per supported
option; do not use `eval` or dynamically named variables.

Implement service-name normalization using `tr` and `sed`, validate explicit
names against `^[a-z0-9][a-z0-9_.-]{0,127}$`, and return status 2 for CLI usage
errors.

- [ ] **Step 4: Make manager/OS checking deterministic in tests**

Have common validation consume `PLATFORM_OS` after
`detect_current_platform`, while tests may preset `WARI_TEST_PLATFORM_OS` only
through a small source-test seam:

```bash
detect_service_platform() {
    if [[ -n "${WARI_TEST_PLATFORM_OS:-}" ]]; then
        PLATFORM_OS="$WARI_TEST_PLATFORM_OS"
        return 0
    fi
    detect_current_platform
}
```

The seam must be documented as internal test-only behavior and must not bypass
any production validation when unset. Reject `systemd` unless the resulting OS
is `linux`; accept Supervisor for `linux` and `darwin` only.

- [ ] **Step 5: Verify parser behavior**

Run:

```bash
bash tests/test-service.sh
```

Expected: parser/default tests pass; renderer-oriented tests do not exist yet.

---

### Task 3: Validate accounts, scalar values, paths, and state defaults

**Files:**
- Modify: `wari`
- Test: `tests/test-service.sh`

**Interfaces:**
- Consumes: normalized `SERVICE_*` parser globals.
- Produces: `validate_service_user`, `validate_service_scalar`, `resolve_service_path`, `resolve_macos_user_home`, and finalized absolute `SERVICE_PROJECT_ROOT`, `SERVICE_STATE_DIR`, `SERVICE_XDG_CONFIG_HOME`, `SERVICE_XDG_DATA_HOME`, and `SERVICE_LOG_FILE`.

- [ ] **Step 1: Add failing common-validation tests**

Add fixture-controlled tests for:

```bash
assert_fails 'service rejects root by name' \
    validate_service_user root
assert_fails 'service rejects missing account' \
    validate_service_user wari-user-that-does-not-exist
assert_fails 'service rejects relative state directory' \
    validate_service_state_dir relative/state
assert_fails 'service rejects parent state component' \
    validate_service_state_dir /var/lib/wari/../escape
assert_fails 'service rejects zero port' validate_service_port 0
assert_fails 'service rejects high port' validate_service_port 65536
assert_fails 'service rejects public bind' validate_service_host 0.0.0.0
assert_fails 'service rejects zero timeout' validate_service_stop_timeout 0
```

Resolve the current non-root test user with `id -un` and skip only the
non-root success assertion when the test suite itself is running as UID 0 with
no suitable fixture account. Add successful boundaries for ports 1/65535,
hosts `127.0.0.1`/`::1`, timeout 1/86400, and paths containing spaces and `%`.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
bash tests/test-service.sh
```

Expected: the new validation function calls fail as undefined.

- [ ] **Step 3: Implement strict validation and path resolution**

Implement numeric validation without external arithmetic surprises:

```bash
[[ "$value" =~ ^[0-9]+$ ]] || return 2
((10#$value >= minimum && 10#$value <= maximum)) || return 2
```

Before arithmetic, reject values with more digits than the maximum to remain
safe on Bash 3.2. Reject empty values, NUL-unrepresentable input, CR/LF, ASCII
control characters, and state paths containing `.` or `..` components. Existing
paths resolve with physical `pwd -P`; a state path whose final directory does
not yet exist is normalized from its nearest existing physical parent.

Reject an account name beginning with `-` or containing whitespace/control
characters before invoking `id -u "$SERVICE_USER"`, then reject numeric result
0. This ordering avoids option injection without relying on GNU-style `--`,
which is not portable to every macOS utility. Do not assume a same-named
primary group.

- [ ] **Step 4: Implement OS-specific state defaults**

Use `/var/lib/wari/$SERVICE_NAME` on Linux. On macOS resolve the account home
from the native account database (`dscl . -read /Users/$SERVICE_USER
NFSHomeDirectory`), validate it as absolute, and use:

```text
<home>/Library/Application Support/Wari/<service-name>
```

If native lookup fails, return a diagnostic requiring `--state-dir`. Derive:

```bash
SERVICE_XDG_CONFIG_HOME="$SERVICE_STATE_DIR/config"
SERVICE_XDG_DATA_HOME="$SERVICE_STATE_DIR/data"
SERVICE_LOG_FILE="$SERVICE_STATE_DIR/service.log"
```

- [ ] **Step 5: Verify common validation**

Run:

```bash
bash tests/test-service.sh
```

Expected: common validation/default tests pass on the current OS; simulated
Linux and Darwin defaults pass through the test seam.

---

### Task 4: Build and preflight the three service profiles

**Files:**
- Modify: `wari`
- Test: `tests/test-service.sh`

**Interfaces:**
- Consumes: validated common `SERVICE_*` values and exact `WARI_PROJECT_ROOT`/`WARI_RUNTIME_DIR`.
- Produces: `build_classic_service_profile`, `build_octane_service_profile`, `build_caddyfile_service_profile`, and populated `SERVICE_START_ARGUMENTS`/`SERVICE_RELOAD_ARGUMENTS` arrays.

- [ ] **Step 1: Add failing classic profile tests**

Create `public/index.php` in the fixture and assert the model arguments are
exactly:

```text
<project>/wari
frankenphp
php-server
--listen
127.0.0.1:8000
--root
<project>/public
```

Add failures for a missing root, root without `index.php`, `--workers` on the
classic profile, and non-loopback host. Assert `SERVICE_RELOAD_ARGUMENTS` is
empty.

- [ ] **Step 2: Add failing Octane profile tests**

Build fixture files `artisan`, `vendor/autoload.php`,
`vendor/laravel/octane/composer.json`, `composer.json`, and
`public/frankenphp-worker.php`. Assert the required argument prefix and that
omitted worker options produce no flags. Then set `--workers=4` and
`--max-requests=500` and assert both exact arguments are appended. Assert reload
is:

```text
<project>/wari php artisan octane:reload
```

Add one failure per missing prerequisite and reject classic/Caddyfile-only
options.

- [ ] **Step 3: Add failing Caddyfile profile tests**

Extend the fake runtime FrankenPHP command so:

```bash
case "${1-}" in
    validate) exit "${FAKE_VALIDATE_STATUS:-0}" ;;
esac
```

Assert start and reload arrays use the absolute config path. Assert missing
config and a fake `validate --config` failure both fail. Capture validation
arguments to prove the bundled runtime, not a global `frankenphp`, is used.

- [ ] **Step 4: Run profile tests and confirm RED**

Run:

```bash
bash tests/test-service.sh
```

Expected: profile builder/preflight tests fail as undefined.

- [ ] **Step 5: Implement profile-specific validation and arrays**

Dispatch without auto-detection:

```bash
case "$SERVICE_PROFILE" in
    classic) build_classic_service_profile ;;
    octane) build_octane_service_profile ;;
    caddyfile) build_caddyfile_service_profile ;;
esac
```

Resolve `--root` and `--config` relative to the physical project root. For
Octane, inspect static files only; do not boot Artisan. Confirm the installed
package by the regular directory and package metadata under
`vendor/laravel/octane`. For Caddyfile, capture all validator output, replay it
to stderr only on failure, and never allow it to reach generator stdout.

- [ ] **Step 6: Verify profile construction**

Run:

```bash
bash tests/test-service.sh
```

Expected: all common and profile model tests pass.

---

### Task 5: Render and guide systemd services

**Files:**
- Modify: `wari`
- Test: `tests/test-service.sh`

**Interfaces:**
- Consumes: complete manager-neutral service model and argument arrays.
- Produces: `escape_systemd_value`, `render_systemd_command`, `render_systemd_service`, and `print_systemd_instructions`.

- [ ] **Step 1: Add failing systemd output tests**

For each profile, capture stdout and stderr separately:

```bash
service_main generate systemd \
    --profile=classic \
    --user="$TEST_USER" \
    --name=wari-test \
    >"$SERVICE_TMP/systemd.out" \
    2>"$SERVICE_TMP/systemd.err"
```

Assert the unit includes exact keys:

```ini
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=<user>
WorkingDirectory=<absolute-project>
ExecStart=<escaped argument vector>
Environment=XDG_CONFIG_HOME=<state>/config
Environment=XDG_DATA_HOME=<state>/data
Restart=always
RestartSec=5
KillSignal=SIGTERM
KillMode=control-group
TimeoutStopSec=<profile default>
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
```

Assert the default state emits `StateDirectory=wari/wari-test` and
`StateDirectoryMode=0750`. Assert a custom state directory omits
`StateDirectory=` and its stderr instructions contain the exact `sudo install
-d -m 0750 -o <user> <state>` preparation command.

Assert Octane and Caddyfile include their exact `ExecReload`; classic does not.
Assert instructions include the exact suggested install destination,
`daemon-reload`, `enable --now`, `status`, journald, restart/removal commands,
and reload only for reloadable profiles.

- [ ] **Step 2: Add failing systemd escaping tests**

Use a fixture project and Caddyfile path containing spaces and `%`. Assert
literal `%` becomes `%%` where systemd performs specifier expansion and that
arguments remain individually quoted. Add CR/LF/control-character cases that
must fail with an empty output file.

- [ ] **Step 3: Run systemd tests and confirm RED**

Run:

```bash
WARI_TEST_PLATFORM_OS=linux bash tests/test-service.sh
```

Expected: systemd renderer tests fail as undefined or missing output.

- [ ] **Step 4: Implement the systemd serializer and renderer**

Implement a serializer that treats each command argument separately, doubles
literal `%`, escapes backslash and double quote, and double-quotes every
argument. Do not delegate quoting to `%q`, whose output is shell syntax rather
than systemd syntax.

Render into a private temporary file or a local variable. Use this ordering:

```text
[Unit] -> [Service] identity/paths -> state/environment -> commands ->
lifecycle/logging -> [Install]
```

Only copy the completed render to stdout after every renderer and instruction
value has validated.

- [ ] **Step 5: Implement systemd instructions**

Print instructions only to stderr. Use the suggested local filename
`$SERVICE_NAME.service`,/ and `/etc/systemd/system/$SERVICE_NAME.service` as the
installation destination. Include `systemctl reload` only if the model has a
reload array. Do not execute or probe systemctl.

- [ ] **Step 6: Verify systemd generation**

Run:

```bash
WARI_TEST_PLATFORM_OS=linux bash tests/test-service.sh
```

Expected: all systemd exact-output, escaping, channel, and instruction tests
pass.

---

### Task 6: Render and guide Supervisor services

**Files:**
- Modify: `wari`
- Test: `tests/test-service.sh`

**Interfaces:**
- Consumes: complete manager-neutral service model and argument arrays.
- Produces: `escape_supervisor_value`, `render_supervisor_command`, `render_supervisor_service`, and `print_supervisor_instructions`.

- [ ] **Step 1: Add failing Supervisor output tests**

Generate all three profiles and assert exact program settings:

```ini
[program:wari-test]
process_name=%(program_name)s
numprocs=1
command=<escaped argument vector>
directory=<absolute-project>
user=<user>
environment=XDG_CONFIG_HOME="<state>/config",XDG_DATA_HOME="<state>/data"
autostart=true
autorestart=true
startsecs=3
startretries=3
stopsignal=TERM
stopasgroup=true
killasgroup=true
stopwaitsecs=<profile default>
redirect_stderr=true
stdout_logfile=<state>/service.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
```

Assert stderr includes the exact state-directory creation command, explains
`[include] files=`, labels `/etc/supervisor/conf.d` only as a common Linux
location, requires an absolute `-c /absolute/path/supervisord.conf`, and shows
`reread`, `update`, `status`, restart, stop, and removal operations. Assert the
Octane/Caddy reload command is shown separately while classic shows only
`supervisorctl restart`.

- [ ] **Step 2: Add failing Supervisor escaping tests**

Cover spaces, quotes, backslashes, commas in environment values, and literal
percent signs. Assert Supervisor interpolation literals are doubled and that
the generated command remains one executable plus its original arguments. Add
newline/control-character failures and verify stdout remains empty.

- [ ] **Step 3: Run Supervisor tests and confirm RED**

Run:

```bash
bash tests/test-service.sh
```

Expected: Supervisor renderer tests fail as undefined or missing output.

- [ ] **Step 4: Implement Supervisor serialization and rendering**

Serialize command arguments according to Supervisor's command parser rather
than shell rules. Escape `%` as `%%` before Supervisor interpolation, quote
whitespace-bearing arguments, and separately encode quoted comma-separated
environment values. Render to a completed temporary buffer before stdout.

Use the state root as the single directory Supervisor must be instructed to
create. The service user owns it; Supervisor writes `service.log`, while Caddy
creates its `config` and `data` children.

- [ ] **Step 5: Implement OS-aware Supervisor instructions**

On Linux, show `/etc/supervisor/conf.d/$SERVICE_NAME.conf` as a common example
and explicitly tell the user to verify that the active `[include]` glob covers
it. On macOS, do not invent a universal path: list Supervisor's documented
config search locations, tell the user to inspect the chosen file's `[include]`
section, and use an absolute `-c` path for every shown `supervisorctl` command.

- [ ] **Step 6: Verify Supervisor generation on both simulated OS values**

Run:

```bash
WARI_TEST_PLATFORM_OS=linux bash tests/test-service.sh
WARI_TEST_PLATFORM_OS=darwin bash tests/test-service.sh
```

Expected: both runs pass, including Linux and macOS default-state instruction
branches.

---

### Task 7: Integrate public dispatch and atomic output behavior

**Files:**
- Modify: `wari` in `launcher_usage`, `launcher_main`, and service orchestration
- Test: `tests/test-launcher.sh`
- Test: `tests/test-service.sh`

**Interfaces:**
- Consumes: parser, common validation, profile builder, and selected renderer/instruction functions.
- Produces: public `./wari service generate ...` with runtime validation before profile/renderer execution.

- [ ] **Step 1: Add failing public-command tests**

Update launcher help assertions to require:

```text
service          Generate production service configuration
```

Before setup, invoke a valid-looking service command and assert status 1,
`./wari setup` guidance on stderr, no network marker, no `.wari` creation, and
empty stdout. In a ready fixture, invoke the public service command and assert
the fake runtime validation occurs before generated output.

- [ ] **Step 2: Add late-failure atomicity tests**

Create a test-only renderer failure after a valid profile model and assert:

```bash
assert_eq '0' "$(wc -c <"$SERVICE_TMP/failed.out" | tr -d ' ')" \
    'late service rendering failure leaves stdout empty'
```

Also assert instructions are not printed as if installation succeeded after a
render failure.

- [ ] **Step 3: Run public tests and confirm RED**

Run:

```bash
bash tests/test-launcher.sh
bash tests/test-service.sh
```

Expected: help/dispatch tests fail because `service` is not yet public.

- [ ] **Step 4: Wire service dispatch**

Add `service` to `launcher_usage` and dispatch it explicitly:

```bash
service)
    shift
    validate_runtime "$WARI_PROJECT_ROOT" || {
        runtime_not_ready
        return 1
    }
    service_main "$@"
    ;;
```

Do not add `service` to `dispatch_runtime`: it is a launcher operation that
uses the installed runtime for validation, not a generated `.wari/service`
wrapper.

Make `service_main` perform this sequence:

```text
parse -> common validation -> profile preflight/model -> render privately ->
print config to stdout -> print instructions to stderr
```

If instruction construction itself can fail, construct instructions privately
before printing either channel.

- [ ] **Step 5: Verify public dispatch and no-side-effect failures**

Run:

```bash
bash tests/test-launcher.sh
bash tests/test-service.sh
```

Expected: both scripts pass and invalid public calls neither download nor
create runtime/service state.

---

### Task 8: Add native syntax checks and CI coverage

**Files:**
- Modify: `tests/test-service.sh`
- Modify: `.github/workflows/test.yml`
- Modify: `README.md` development test list

**Interfaces:**
- Consumes: generated systemd/Supervisor text from Task 7.
- Produces: conditional syntax verification locally and mandatory portable exact-output coverage on every CI platform.

- [ ] **Step 1: Add conditional native parser tests**

For systemd, when both Linux and `systemd-analyze` are present, write the
already generated fixture unit beneath the test temporary directory and run:

```bash
systemd-analyze verify "$SERVICE_TMP/wari-test.service"
```

For Supervisor, do not use `supervisord -t`: in current Supervisor that flag
means “strip ANSI”, not “test configuration”. When `supervisord` and
`supervisorctl` are present, copy the generated program into the temporary
directory while changing only `autostart=true` to `autostart=false`. Create a
minimal parent configuration with a temporary Unix socket, pid file, activity
log, child log directory, the required `rpcinterface:supervisor` section, a
matching `supervisorctl` server URL, and an `[include]` glob for that program.
Start it in the foreground and shut it down through the temporary socket:

```bash
supervisord -n -c "$SERVICE_TMP/supervisord.conf" \
    >"$SERVICE_TMP/supervisord.native.out" 2>&1 &
SUPERVISORD_TEST_PID=$!

# Poll for the configured Unix socket and process liveness with a bounded loop.
supervisorctl -c "$SERVICE_TMP/supervisord.conf" shutdown
wait "$SUPERVISORD_TEST_PID"
```

Use a bounded condition loop rather than `sleep`; on any failure print the
captured daemon diagnostics and terminate the recorded test PID during trap
cleanup. This exercises Supervisor's real parser without launching the Wari
fixture service. If either native tool is absent, print a TAP-style
informational line without counting a failure.

- [ ] **Step 2: Run native checks where available**

Run:

```bash
bash tests/test-service.sh
```

Expected: exact-output tests always pass; installed native parsers also accept
their generated files.

- [ ] **Step 3: Add service tests to every offline CI target**

Append the exact command to the offline wrapper-test step:

```yaml
- name: Run offline wrapper and service tests
  shell: bash
  run: |
    bash tests/test-wrappers.sh
    bash tests/test-create-project.sh
    bash tests/test-service.sh
```

Do not install Supervisor merely for the offline matrix; native parsing remains
conditional while deterministic renderer tests are mandatory.

- [ ] **Step 4: Update the documented offline suite**

Add:

```bash
bash tests/test-service.sh
```

to README's offline test sequence.

- [ ] **Step 5: Verify workflow syntax and the focused suite**

Run:

```bash
bash tests/test-service.sh
git diff --check
```

Expected: service tests pass and no whitespace errors are reported.

---

### Task 9: Write production user documentation

**Files:**
- Modify: `README.md`
- Create: `docs/production/README.md`
- Create: `docs/production/profiles.md`
- Create: `docs/production/systemd.md`
- Create: `docs/production/supervisor.md`
- Modify: `docs/compatibility/README.md`
- Modify when evidence exists: `docs/compatibility/laravel.md`, `docs/compatibility/symfony.md`, `docs/compatibility/codeigniter.md`

**Interfaces:**
- Consumes: final CLI/output/lifecycle behavior.
- Produces: copyable generation commands and truthful support status without expanding Wari into a proxy or deployment manager.

- [ ] **Step 1: Add the production boundary and quick start**

Document this exact flow in `docs/production/README.md`:

```text
pull/publish code -> wari setup --yes -> composer install -> service generate
-> review/install service -> configure external reverse proxy
```

State explicitly that Wari does not manage TLS, Nginx, Apache, secrets,
databases, system privileges, atomic releases, or rollback. Explain that all
generated application listeners are loopback-only.

- [ ] **Step 2: Document profile choice**

In `profiles.md`, recommend:

```text
classic: broad compatibility and request isolation
octane: Laravel applications intentionally prepared for long-lived workers
caddyfile: framework/project-owned routing or worker configuration
```

Include each exact start/reload command, explain why classic has no reload, and
list long-lived worker state/memory cautions. Do not imply worker safety from a
successful render.

- [ ] **Step 3: Document systemd operations**

In `systemd.md`, include generation, redirected output, review, installation,
`daemon-reload`, enable/start, status, journald, profile reload versus restart,
service-file update, disable, and removal. Explain default versus custom state
directory ownership and that systemd generation is Linux-only.

- [ ] **Step 4: Document Supervisor on Linux and macOS**

In `supervisor.md`, include state-directory preparation, log location and
rotation, `[include]` discovery, explicit `-c` usage, reread/update/status,
profile reload versus restart, stop, config removal, and the absence of one
universal macOS include directory. State that Supervisor must already be
installed and configured.

- [ ] **Step 5: Update README and compatibility claims**

Add `service` to README usage and link the production index. Keep `wari serve`
labeled development-only. Update the compatibility matrix's test-environment
wording to distinguish historical development checks from service-generator
coverage. Change a framework's worker/production status only when a live test
has actually run; otherwise retain “Not tested” and link to the planned
production procedure.

- [ ] **Step 6: Verify documentation commands match help**

Run:

```bash
rg -n './wari service generate|--profile=|--state-dir|--stop-timeout' \
  README.md docs/production docs/compatibility
bash wari help
git diff --check
```

Expected: every documented option appears in CLI help and every Caddyfile
example uses the approved `--config=Caddyfile` spelling.

---

### Task 10: Synchronize version 0.3.0 and the canonical lock

**Files:**
- Modify: `wari`
- Modify: `install.sh`
- Modify: `wari.lock`
- Modify: all test fixtures/assertions returned by `rg -n '0\.2\.1' tests`
- Modify: README release example if it describes the current version

**Interfaces:**
- Consumes: stable implementation and documentation from Tasks 1-9.
- Produces: a self-consistent Wari 0.3.0 launcher/initializer/lock pair.

- [ ] **Step 1: Change version expectations to 0.3.0 and confirm RED**

Update expected current-Wari values in tests from `0.2.1` to `0.3.0`, preserving
fixtures that intentionally represent older or update-target versions. Run:

```bash
bash tests/test-installer.sh
bash tests/test-lock.sh
bash tests/test-launcher.sh
```

Expected: failures report that production files still identify as 0.2.1.

- [ ] **Step 2: Update launcher and initializer versions**

Change only the release constants:

```bash
WARI_VERSION='0.3.0'
```

in `wari` and `install.sh`. Update current-version URLs/assertions in initializer
tests while retaining explicit cross-version fixtures used to test update
behavior.

- [ ] **Step 3: Regenerate the lock from exact existing dependency versions**

Use the repository generator with the unchanged runtime selections:

```bash
./tools/generate-lock.sh 0.3.0 1.12.7 2.8.11 static
```

Capture its complete output, review that only `wari_version`, `wari_sha256`,
and metadata derived from the exact official versions changed as expected,
then replace `wari.lock` with that generated content. Do not hand-edit the
launcher digest and do not skip network/checksum validation.

- [ ] **Step 4: Verify the tracked pair and version-focused tests**

Run:

```bash
bash wari --validate-pair wari.lock
bash tests/test-installer.sh
bash tests/test-lock.sh
bash tests/test-launcher.sh
bash tests/test-update.sh
bash tests/test-initializer.sh
```

Expected: pair validation and every version-sensitive test pass.

- [ ] **Step 5: Audit remaining version strings**

Run:

```bash
rg -n '0\.2\.1|0\.3\.0' \
  wari install.sh wari.lock README.md tests docs/production docs/compatibility
```

Expected: 0.3.0 identifies current code; every retained 0.2.1 occurrence is an
intentional historical/update fixture and is explained by its surrounding
test.

---

### Task 11: Run complete verification and record honest compatibility status

**Files:**
- Modify only if results require correction: `README.md`, `docs/production/*`, `docs/compatibility/*`

**Interfaces:**
- Consumes: the complete Wari 0.3.0 implementation and tests.
- Produces: verified offline behavior plus an explicit record of which native service lifecycle checks did or did not run.

- [ ] **Step 1: Run every offline test from a clean shell**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-lock.sh
bash tests/test-launcher.sh
bash tests/test-setup.sh
bash tests/test-update.sh
bash tests/test-initializer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
bash tests/test-service.sh
```

Expected: every script exits 0 and reports zero failures.

- [ ] **Step 2: Run static repository checks**

Run:

```bash
bash -n wari install.sh tools/generate-lock.sh tests/*.sh
git diff --check
git status --short
```

Expected: syntax and whitespace checks pass; status contains only intentional
unstaged implementation, test, lock, spec, plan, and documentation changes.

- [ ] **Step 3: Run the existing real-runtime integration test**

Run only with network approval:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

Expected: locked artifacts install, wrappers validate, project creation works,
the loopback server answers HTTP, and cleanup terminates the server.

- [ ] **Step 4: Exercise native production lifecycles where hosts are available**

On Linux/systemd, Linux/Supervisor, and macOS/Supervisor targets, follow the
new docs with a disposable application and service name. For each available
target record:

```text
generate -> native config verify -> install -> start -> HTTP readiness ->
forced process crash/restart -> graceful reload (if supported) -> stop ->
state/log ownership -> remove
```

Use a reverse proxy for the final HTTP check, but keep proxy configuration
outside Wari. Never claim an unavailable target passed.

- [ ] **Step 5: Update compatibility wording from observed evidence only**

If all lifecycle checks for a combination pass, record the OS, architecture,
Wari, FrankenPHP, framework, and service-manager versions plus exact commands
in the appropriate guide. If a target was unavailable, leave it explicitly
“Not tested”; do not convert generated-config coverage into production
verification.

- [ ] **Step 6: Present the final unstaged diff for user review**

Run:

```bash
git diff --stat
git status --short
```

Report test counts and commands from fresh output, identify any unrun live
matrix entries, and remind the user that no files were staged, committed, or
pushed.
