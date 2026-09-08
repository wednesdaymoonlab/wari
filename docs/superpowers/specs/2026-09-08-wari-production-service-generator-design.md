# Wari production service generator design

Date: 2026-09-08
Status: Approved and implemented for Wari 0.3.0

## Summary

Wari will generate complete systemd or Supervisor configurations for running a
project-local FrankenPHP process as a foreground production service. The user
will save and install the generated configuration, configure an external
reverse proxy such as Nginx or Apache, and remain responsible for deployment,
TLS, secrets, and operating-system administration.

The generator never writes a service configuration, invokes `sudo`, modifies a
service manager, or starts a process. Configuration is written to standard
output. Installation and operation instructions are written to standard error,
so the configuration can be redirected directly to a file.

The first release supports Linux and macOS. systemd output is available only on
Linux. Supervisor output is available on Linux and macOS. Native macOS launchd
support is outside this design.

## Goals

- Turn an existing Wari-enabled PHP project into a predictable foreground
  service managed by systemd or Supervisor.
- Support classic FrankenPHP, Laravel Octane with FrankenPHP, and a
  project-owned Caddyfile without framework auto-detection.
- Bind generated classic and Octane services to loopback for use behind a
  separately managed reverse proxy.
- Generate safe, target-specific syntax with absolute paths, explicit process
  lifecycle behavior, writable Caddy state, and actionable installation
  instructions.
- Fail before emitting configuration when Wari can prove that the requested
  service cannot run.
- Keep production policy separate from runtime acquisition: `wari setup`
  installs and verifies the runtime; `wari service generate` describes how a
  service manager should run it.

## Non-goals

- Installing, enabling, starting, stopping, or removing services.
- Invoking `sudo` or editing system configuration.
- Generating launchd, Nginx, Apache, TLS, domain, or secret configuration.
- Managing queue workers, schedulers, or other auxiliary application services.
- Framework auto-detection.
- Zero-downtime release switching, rollback, or deployment orchestration.
- Adding a persistent Wari production configuration file.
- Guaranteeing worker-mode safety for arbitrary PHP applications.

## User workflow

A production deployment remains an explicit sequence:

1. Pull or publish the PHP project on the target Linux or macOS server.
2. Run `./wari setup --yes` and install Composer application dependencies.
3. Generate a service configuration from the project root.
4. Review and install the generated file using the instructions printed by
   Wari.
5. Point a separately managed Nginx, Apache, or other reverse proxy at the
   loopback address used by the service.

Example:

```bash
./wari service generate systemd \
  --profile=octane \
  --user=www-data \
  --name=my-app \
  --workers=4 \
  --max-requests=500 \
  > my-app.service
```

## CLI contract

The public command is:

```text
./wari service generate <systemd|supervisor> \
  --profile=<classic|octane|caddyfile> \
  --user=<os-user> \
  [options]
```

`--profile` and `--user` are required. The generator rejects the root account,
whether it is written as `root` or resolves to UID 0. The named account must
exist on the machine where generation runs.

Common options are:

- `--name=<name>`: service name. By default Wari derives it from the physical
  project directory basename, converts ASCII letters to lowercase, replaces
  runs of characters outside `[a-z0-9_.-]` with `-`, and trims leading and
  trailing punctuation. An explicitly supplied name must already match
  `[a-z0-9][a-z0-9_.-]{0,127}`. An empty derived name is an error.
- `--state-dir=<absolute-path>`: writable Caddy state root. Relative paths,
  `.` or `..` path components, newlines, and control characters are rejected.
- `--stop-timeout=<seconds>`: time the service manager allows graceful stop
  before forceful termination. It must be an integer from 1 through 86400.

Profile-specific options are:

| Profile | Accepted options | Defaults |
| --- | --- | --- |
| `classic` | `--root`, `--host`, `--port` | `public`, `127.0.0.1`, `8000` |
| `octane` | `--host`, `--port`, `--workers`, `--max-requests` | `127.0.0.1`, `8000`; Octane defaults for omitted worker settings |
| `caddyfile` | `--config` | `Caddyfile` |

`--host` accepts only `127.0.0.1` and `::1` in this release. `--port` accepts
integers from 1 through 65535. Wari validates the value but does not require the
port to be unused during generation.

`--workers` and `--max-requests` must be positive integers when supplied. Wari
omits their Octane flags when the options are absent instead of duplicating an
upstream default that may change. The generator rejects options that do not
belong to the selected profile rather than silently ignoring them.

The default stop timeout is 60 seconds for `classic` and `caddyfile`. The
default for `octane` is 3600 seconds, matching Laravel's conservative
production Supervisor guidance. The user may override either default.

The project root, document root, Caddyfile, launcher, and application entry
points are resolved to absolute paths before rendering. The generated service
never depends on the service manager inheriting the caller's working directory
or `PATH`.

Help and version output follow normal CLI conventions. For a successful
`service generate` operation, standard output contains only the complete
service-manager configuration. Instructions and non-fatal notices go to
standard error. Any generation error produces no configuration on standard
output and returns a non-zero status.

## Profiles

### Classic

Classic mode runs a conventional PHP front-controller application without a
long-lived application worker:

```text
<project>/wari frankenphp php-server \
  --listen <host>:<port> \
  --root <absolute-document-root>
```

The document root must exist and contain `index.php`. This is the broadest
compatibility profile and is the recommended default for an application that
does not explicitly support FrankenPHP worker mode.

The FrankenPHP `php-server` command disables the Caddy admin API, so this
profile has no reload operation. Configuration or application changes require
a service restart.

### Laravel Octane

Octane mode runs:

```text
<project>/wari php artisan octane:start \
  --server=frankenphp \
  --host=<host> \
  --port=<port> \
  [--workers=<workers>] \
  [--max-requests=<max-requests>]
```

The Wari PHP wrapper puts the internal `.wari` wrapper directory first in
`PATH`. Laravel Octane therefore locates the Wari-managed `frankenphp`
executable instead of downloading or selecting an unrelated global binary.

The profile exposes an application-worker reload operation:

```text
<project>/wari php artisan octane:reload
```

Reloading workers is distinct from restarting the outer service. Deployments
must reload or restart Octane so long-lived workers do not continue executing
old application code.

### Caddyfile

Caddyfile mode runs:

```text
<project>/wari frankenphp run --config <absolute-Caddyfile>
```

It is intended for framework-provided worker files, Symfony Runtime,
CodeIgniter worker mode, or any application that needs routing beyond Wari's
classic front-controller behavior.

The profile exposes a Caddy configuration reload operation:

```text
<project>/wari frankenphp reload --config <absolute-Caddyfile>
```

Reload requires the configured Caddy admin endpoint to remain available. A
project that disables or makes that endpoint unreachable must restart the
service instead.

## Validated service model

Argument parsing and profile selection produce one manager-neutral service
model. The model contains:

- manager, profile, service name, service user, and physical project root;
- an argument array for the foreground start process;
- an optional argument array for reload;
- state, config, data, and log paths;
- restart policy and graceful stop timeout; and
- manager-independent description and instruction metadata.

The model stores commands as argument arrays, not shell command strings. Each
renderer serializes the array using its target format's quoting and escaping
rules. This boundary prevents the six manager/profile combinations from
developing different defaults or validation behavior.

Values containing NUL, newlines, carriage returns, or other control characters
are rejected. Literal percent signs and whitespace are escaped for systemd and
Supervisor independently. Generated commands do not invoke a shell.

## Writable service state

Production services explicitly set `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.
They do not depend on `HOME`, and Wari does not invent or overwrite `HOME`.

The default Linux state root is:

```text
/var/lib/wari/<service-name>
```

The default macOS Supervisor state root is:

```text
<service-user-home>/Library/Application Support/Wari/<service-name>
```

Wari resolves the macOS account home through the operating-system account
database. If it cannot resolve a usable absolute home, generation fails and
asks for an explicit `--state-dir`.

The state root contains:

```text
<state-root>/
├── config/
├── data/
└── service.log        # Supervisor only
```

For a default systemd state path, the unit uses `StateDirectory=` and
`StateDirectoryMode=0750`; systemd creates the directory and assigns it to the
configured service user. For a custom state path, installation instructions
include an explicit `install -d` command instead. Supervisor instructions
always include the command needed to create and own the state directory before
starting the service.

Concretely, the default unit emits `StateDirectory=wari/<service-name>` and
sets `XDG_CONFIG_HOME=/var/lib/wari/<service-name>/config` and
`XDG_DATA_HOME=/var/lib/wari/<service-name>/data`. Supervisor sets the same
two environment variables beneath its selected state root and writes its
rotated log to `<state-root>/service.log`.

State lives outside `.wari/` because `wari setup` may atomically replace the
project-local runtime. Runtime replacement must neither erase service state nor
require changing the ownership of the verified runtime tree.

## Common FrankenPHP environment behavior

The current launcher only supplies project-local XDG fallbacks inside the
`php -S` translation path, although the README describes the behavior more
broadly. `wari serve` and the transparent `wari frankenphp` wrapper bypass that
logic. Production work will correct the boundary as a prerequisite.

The generated `.wari/frankenphp` wrapper becomes the common location for
FrankenPHP environment normalization. It preserves explicit
`XDG_CONFIG_HOME` and `XDG_DATA_HOME` values from generated production
services. When those variables and `HOME` are all absent in an ordinary
development invocation, it creates and uses the existing project-local XDG
fallback.

`wari serve` and the `php -S` translation invoke the common FrankenPHP wrapper
instead of bypassing it. Octane continues to find that same wrapper through
`PATH`. No path changes the caller's non-empty `HOME`.

## systemd rendering

systemd generation is accepted only when the target host reports Linux. The
unit contains:

- a unit description and `After=`/`Wants=network-online.target`;
- `Type=simple` and the selected `User=`;
- the absolute `WorkingDirectory=` and `ExecStart=`;
- explicit XDG environment values;
- `Restart=always` with a short restart delay;
- `KillSignal=SIGTERM` and `KillMode=control-group`;
- the selected `TimeoutStopSec=`;
- journal-backed standard output and error;
- `ExecReload=` for Octane and Caddyfile profiles only; and
- `WantedBy=multi-user.target`.

`Restart=always` restarts an exited foreground server but does not override an
intentional `systemctl stop`. Control-group termination ensures nested Octane
and FrankenPHP processes receive service shutdown. systemd provides state
directory ownership for the default state path and journald provides log
retention; Wari does not duplicate either facility.

The installation instructions use the suggested `<name>.service` filename and
show:

```bash
sudo install -m 0644 <name>.service /etc/systemd/system/<name>.service
sudo systemctl daemon-reload
sudo systemctl enable --now <name>.service
sudo systemctl status <name>.service
journalctl -u <name>.service
```

They also show `systemctl reload` only when the selected profile supports it,
plus restart, stop, disable, and configuration-update commands. These are
instructions only; Wari executes none of them.

## Supervisor rendering

Supervisor generation is supported on Linux and macOS. The program section
contains:

- the selected program name and one process instance;
- the escaped foreground `command=` and absolute `directory=`;
- the selected `user=`;
- explicit XDG environment values;
- `autostart=true` and `autorestart=true`;
- startup retry settings;
- `stopsignal=TERM`, `stopasgroup=true`, and `killasgroup=true`;
- the selected `stopwaitsecs=`;
- a state-root `service.log` with finite rotation and backups; and
- redirected standard error.

Supervisor has no universal per-program include directory, especially across
Linux distributions and macOS installations. Wari therefore does not claim
that `/etc/supervisor/conf.d` is universal and does not edit
`supervisord.conf`.

Instructions explain that the generated file must be placed in a path matched
by the `[include] files=` setting of the explicitly selected
`supervisord.conf`. They show `/etc/supervisor/conf.d` as a common Linux
example, show how to inspect the active macOS configuration, recommend using
absolute `-c` paths, and then show:

```bash
sudo supervisorctl -c /absolute/path/supervisord.conf reread
sudo supervisorctl -c /absolute/path/supervisord.conf update
sudo supervisorctl -c /absolute/path/supervisord.conf status <name>
```

Because Supervisor has no `ExecReload` equivalent, profile instructions show
the Octane or Caddy reload command separately. Classic mode instructs the user
to run `supervisorctl restart <name>`.

## Preflight validation

All checks finish before Wari emits the rendered configuration.

Common checks verify:

- the tracked launcher and lock form a valid pair;
- the installed runtime is current, complete, executable, and matches the
  lock and current platform;
- the current OS supports the requested manager;
- the service account exists and is not UID 0;
- the project root is a physical absolute directory;
- name, state path, timeout, and profile options meet this contract; and
- host and port values meet the loopback-only policy where applicable.

Profile checks verify:

- `classic`: the resolved document root exists and contains `index.php`;
- `octane`: `artisan`, `vendor/autoload.php`, `composer.json`, the installed
  Laravel Octane package, and `public/frankenphp-worker.php` exist; and
- `caddyfile`: the resolved configuration file exists and the locked
  FrankenPHP binary accepts it with `validate --config <absolute-Caddyfile>`.

The Octane check is static and must not boot the user's application merely to
generate text. The Caddy validation command is read-only and its diagnostics
are forwarded on failure.

No check claims that a PHP application's own code is safe for long-lived
worker mode. Framework compatibility remains documented and tested per
framework.

## Error behavior

Unknown managers, profiles, options, duplicate scalar options, missing option
values, incompatible profile options, unsafe values, missing prerequisites,
or failed Caddy validation return a non-zero status with a concise diagnostic.

Rendering is completed in memory or a private temporary file before anything
is copied to standard output. Therefore a late renderer error cannot leave a
truncated configuration that looks usable. Temporary artifacts use the same
strict cleanup and signal behavior as existing Wari operations.

Instructions never include application secrets or values read from `.env`.
The generator does not print the process environment.

## Testing

Automated tests cover:

- all six profile and manager combinations;
- exact foreground commands and reload availability;
- manager-neutral defaults and profile-specific overrides;
- config-only standard output and instruction-only standard error;
- no standard output on every validation or rendering failure;
- missing, duplicate, unknown, and cross-profile options;
- root by name and by UID, nonexistent users, and unsupported manager/OS
  combinations;
- invalid names, paths, hosts, ports, worker counts, request counts, and stop
  timeouts;
- spaces and literal percent signs in representable paths;
- rejection of newline, control-character, and interpolation injection;
- absolute paths and stable working directories;
- systemd state, journal, restart, process-group, stop, and reload settings;
- Supervisor environment, state log, rotation, restart, process-group, stop,
  and reload instructions;
- profile preflight success and failure;
- common XDG behavior for direct FrankenPHP, `wari serve`, `php -S`, Octane's
  PATH lookup, and caller-provided environment values; and
- all existing launcher, setup, wrapper, update, and live-install regressions.

Where available, tests pass generated units to `systemd-analyze verify` and
generated Supervisor programs to Supervisor's configuration parser. These
tool-assisted checks may be conditional in the portable offline suite, but
exact renderer tests always run.

Before documentation calls a manager/profile combination production verified,
manual or dedicated live integration tests must exercise:

- Linux with systemd;
- Linux with Supervisor;
- macOS with Supervisor;
- startup, readiness, crash restart, normal stop, and forced timeout;
- Octane worker reload after an application-code change;
- Caddyfile configuration reload;
- state and log ownership under the configured non-root account; and
- reverse-proxied HTTP requests during normal operation and reload.

## Documentation

The main README will introduce `wari service generate` and link to:

- `docs/production/README.md` for the supported production boundary;
- `docs/production/systemd.md` for generation, installation, journald, reload,
  update, and removal;
- `docs/production/supervisor.md` for include configuration, state/log setup,
  Linux/macOS differences, reload, update, and removal; and
- `docs/production/profiles.md` for classic, Octane, and Caddyfile selection.

Compatibility pages remain evidence-based. Laravel Octane, Symfony worker
mode, and other profiles are not marked verified merely because a valid service
file can be rendered. Their status changes only after the corresponding live
application test passes.

The existing compatibility matrix currently records results from an older
Wari version and a macOS-only run. Production documentation will call this out
until the matrix is repeated with the released service generator on supported
targets.

## Release boundary

This feature changes the public Wari command interface and generated internal
wrappers. Its release must update the embedded Wari version and regenerate the
canonical `wari.lock` launcher digest using the existing release process.
Service generation itself does not modify `wari.lock`, `.wari/`, application
files, Git state, or operating-system state.
