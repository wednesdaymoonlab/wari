# Wari Portable PHP Runtime Design

**Date:** 2026-09-04
**Status:** Dispatcher layout revision implemented and verified

**Repository:** `git@github.com:wednesdaymoonlab/wari.git`
**License:** MIT

## 1. Purpose

Wari installs a project-local PHP development runtime without requiring a
system PHP installation. It downloads official FrankenPHP and Composer
artifacts into a hidden `.wari/` directory in the current project and exposes
one stable `wari` command dispatcher for PHP, Composer, and local web serving.

Wari v1 is intended for local development. It exposes the underlying
FrankenPHP command for advanced and production-oriented configuration, but it
does not manage production deployment, TLS, process supervision, or services.

## 2. Workspace and repository layout

The development workspace has two sibling directories:

```text
wari/
├── core/        # Git repository containing all Wari source and documentation
└── playground/  # Untracked manual testing area outside the Git repository
```

The `core/` repository will contain:

```text
core/
├── .github/workflows/test.yml
├── docs/superpowers/specs/
├── tests/
│   ├── fixtures/frankenphp-release.json
│   ├── test-installer.sh
│   ├── test-wrappers.sh
│   └── test-live-install.sh
├── install.sh
├── README.md
├── LICENSE
└── .gitignore
```

The repository and Wari-authored source code are released under the MIT
License. Third-party FrankenPHP and Composer artifacts retain their respective
upstream licenses and are downloaded rather than redistributed by Wari.

Manual testing runs the installer from `playground/`:

```bash
cd playground
bash ../core/install.sh
```

The resulting `playground/.wari/` directory and `playground/wari` dispatcher
are not part of the Git repository.

## 3. Supported platforms and runtime policy

Wari v1 supports:

- Linux x86_64
- Linux ARM64
- macOS Intel
- macOS Apple Silicon

Windows, Git Bash, and WSL are not officially supported in v1.

Wari downloads official FrankenPHP standalone binaries. PHP is the version
embedded in the selected FrankenPHP release; Wari does not independently
select or install PHP versions. Dynamic PHP extension installation is outside
v1 scope. Users can inspect the embedded extensions with `./wari php -m`.

On Linux, users choose one of two official build types:

- `static` (default): fully static/musl build for maximum portability.
- `gnu`: mostly static GNU/glibc build, permitted only when glibc is detected.

Wari does not install or manage dynamic extensions for either build type.

## 4. Installation interface

The primary installation command is:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
```

Because the pipe occupies standard input, interactive prompts read from
`/dev/tty`. If no controlling terminal is available, installation stops unless
the caller supplies `--yes`.

Supported v1 flags are:

```text
--yes
--version <frankenphp-version>
--linux-build <static|gnu>
--help
```

Automation examples:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash -s -- --yes
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | \
  bash -s -- --yes --version 1.12.7 --linux-build static
```

With a TTY and without `--yes`, the installer:

1. Shows the detected project path, operating system, and architecture.
2. Asks for latest stable FrankenPHP or a specific stable version.
3. On Linux, asks for the static or GNU build.
4. Shows the resolved choices and destination.
5. Requests confirmation.

Composer always resolves to the latest stable release in v1. Neither Composer
pinning nor automatic self-update is supported.

If either `./wari` or `./.wari` already exists, including a symbolic link, the
installer stops before performing any download or modification. Update,
reinstall, merge, and uninstall flows are outside v1 scope.

## 5. Release and artifact resolution

Latest FrankenPHP resolves through the official GitHub Releases API. A specific
version accepts `1.2.3` or `v1.2.3` and normalizes it to the `v1.2.3` tag form.
Version input is strictly validated before it is used in a URL.

Wari accepts only published, non-draft, non-prerelease releases. It selects an
asset by exact name:

```text
Linux x86_64 static: frankenphp-linux-x86_64
Linux x86_64 GNU:    frankenphp-linux-x86_64-gnu
Linux ARM64 static:  frankenphp-linux-aarch64
Linux ARM64 GNU:     frankenphp-linux-aarch64-gnu
macOS Intel:         frankenphp-mac-x86_64
macOS Apple Silicon: frankenphp-mac-arm64
```

The installer extracts the matching asset's download URL and SHA-256 digest
from the same release API response. Parsing uses standard shell text tools and
requires an exact asset-name match; `jq` is not required. Missing or ambiguous
metadata is an error. GitHub API rate limiting is reported directly, with no
HTML-scraping or unverified-download fallback.

## 6. Installed project layout

A successful installation creates:

```text
project/
├── public/
├── composer.json
├── wari                    # public executable dispatcher
└── .wari/                  # private project-local runtime
    ├── php
    ├── composer
    ├── serve
    ├── frankenphp
    ├── manifest.json
    └── runtime/
        ├── frankenphp
        ├── composer.phar
        └── php-proxy.php
```

The root-level `wari` file is the only public executable. It accepts a command
name as its first argument and delegates to one of the four executable Bash
wrappers in `.wari/`. The actual upstream artifacts stay under
`.wari/runtime/`.

The dispatcher resolves its own directory as the project root and requires the
adjacent `.wari/` directory. Every internal wrapper resolves `.wari/`, treats
its parent as the project root, changes to that root, and uses `exec` for the
final process. Moving the whole project is supported. Moving `.wari/` or the
dispatcher independently between projects is not a supported contract.
Dispatcher and wrapper symlink relocation are outside v1 scope.

## 7. Wrapper contracts

### 7.1 `wari` dispatcher

The dispatcher supports these exact commands:

```text
php
composer
serve
frankenphp
help
--help
-h
```

It removes the command name and forwards all remaining arguments without
re-parsing them. No argument, `help`, `--help`, and `-h` print usage and exit
successfully. An unknown command prints the usage plus
`Unknown Wari command: <name>` to standard error and exits nonzero. The old
directory interface (`./wari/php`) is intentionally removed; this is a
breaking v1 pre-release layout change.

### 7.2 `wari php`

The PHP wrapper invokes:

```text
runtime/frankenphp php-cli <arguments>
```

Because FrankenPHP `php-cli` accepts a PHP script path rather than parsing all
native PHP CLI modes, Wari routes `--version`/`-v`, `-r`, `-m`, and `-i`
through the internal `runtime/php-proxy.php` compatibility helper. Normal PHP
script paths and Composer continue to execute directly through `php-cli`.

Examples:

```bash
./wari php --version
./wari php script.php
./wari php artisan migrate
./wari php -r 'echo PHP_VERSION;'
```

`./wari php version` is not a supported version command because native PHP
interprets `version` as a script filename.

FrankenPHP's PHP CLI compatibility does not support every native PHP option.
For compatibility with Composer, Wari removes both `-d value` and `-dvalue`
arguments before invocation and prints a warning to standard error identifying
each ignored setting. A bare `-d` without a value is an input error. All other
arguments preserve their original order and boundaries.

### 7.3 `wari composer`

The Composer wrapper exports, only for its process tree:

```text
PHP_BINARY=<absolute-project-path>/.wari/php
PATH=<absolute-project-path>/.wari:$PATH
```

It then invokes the local `composer.phar` through `.wari/php`. Consequently,
Composer and child package scripts that resolve `php` through `PATH` use the
Wari runtime without changing the user's persistent shell environment.

### 7.4 `wari serve`

The development server first requires `<project-root>/public/` to exist. It
then invokes:

```text
runtime/frankenphp php-server \
  --listen 127.0.0.1:8000 \
  --root <absolute-project-root>/public
```

It binds only to loopback by default. It does not accept Wari-specific options
in v1. Users who need a different address, root, domain, worker configuration,
or Caddyfile use the raw FrankenPHP wrapper.

### 7.5 `wari frankenphp`

This transparent wrapper changes to the project root and forwards all
arguments to `runtime/frankenphp`. It provides direct access to FrankenPHP and
Caddy functionality without making those interfaces part of Wari's own API.

## 8. Manifest

`.wari/manifest.json` records the exact installed state:

```json
{
  "wari_version": "0.1.0",
  "frankenphp_version": "v1.12.7",
  "php_version": "8.5.x",
  "composer_version": "2.x.y",
  "os": "darwin",
  "architecture": "arm64",
  "linux_build": null,
  "asset": "frankenphp-mac-arm64",
  "asset_url": "https://github.com/php/frankenphp/releases/...",
  "asset_sha256": "...",
  "checksum_verified": true,
  "slsa_verified": false,
  "installed_at": "UTC timestamp"
}
```

Versions are discovered by executing the staged tools after download, rather
than inferred from user input. The SLSA field remains false because Wari v1
does not depend on GitHub CLI. After installation, Wari displays the upstream
artifact information and an optional `gh attestation verify` command for users
who want to perform provenance verification themselves.

## 9. Atomic installation

Before downloading, the installer creates a uniquely named staging directory
under the current project, such as `.wari-install.ABC123`. The staging
directory contains the complete hidden runtime plus a `wari` dispatcher file
that is not executable by users until publication.

The flow is:

1. Run preflight checks and reject an existing `.wari` or `wari`, including
   symbolic links.
2. Resolve user choices and release metadata.
3. Create staging and install an exit/interrupt cleanup trap.
4. Download FrankenPHP into staging.
5. Verify its SHA-256 digest before making it executable.
6. Download the official Composer installer and published SHA-384 checksum.
7. Verify the Composer installer before executing it.
8. Run the installer with staged FrankenPHP to produce `composer.phar`.
9. Generate the four internal wrappers, root dispatcher, and `manifest.json`.
10. Run staged smoke checks through the internal wrappers.
11. Rename the complete staging directory to `.wari/` atomically.
12. Create `wari` as a hard link to `.wari/wari` using `ln`, which atomically
    fails rather than overwriting a concurrently created destination. Mark the
    dispatcher as owned and retain the internal name so cleanup can prove both
    links refer to the same installer-generated file. The public command
    appears only after the runtime is complete.
13. Run public smoke checks through `./wari`; if they fail, remove only the two
    paths published by this installer run. If they pass, unlink `.wari/wari`,
    clear ownership state, and disable the cleanup traps.

Cleanup may remove only a validated staging path that is directly beneath the
project root and whose basename starts with `.wari-install.`. It must never
remove the project root or any pre-existing user path. Once publication starts,
cleanup may remove `.wari/` and `wari` only when in-memory ownership flags prove
that this installer invocation created them after preflight. During the narrow
interval between hard-link creation and setting the dispatcher ownership flag,
cleanup may remove root `wari` while the internal source exists only when
Bash's `-ef` test proves it is the same file as the installer-generated
`.wari/wari` source. If another process replaces root `wari`, cleanup preserves
that replacement while removing the runtime owned by this installation.

Network failure, checksum mismatch, invalid metadata, insufficient disk space,
failed smoke tests, and handled interruption leave neither `.wari/` nor `wari`
behind. Because two filesystem entries cannot be published with one rename, a
power loss or `SIGKILL` between publication steps can leave a complete hidden
`.wari/` without the public dispatcher. The next run detects that path and
stops for manual review rather than overwriting it.

## 10. Security policy

The installer:

- Uses Bash strict mode (`set -Eeuo pipefail`).
- Never uses `sudo`, a package manager, `eval`, or persistent shell changes.
- Downloads only through HTTPS from fixed official hosts.
- Uses `curl` with failure reporting, redirects, and bounded retries.
- Verifies the FrankenPHP SHA-256 digest obtained from release metadata.
- Verifies the official Composer installer with its published SHA-384 value.
- Has no `--skip-verification` option.
- Quotes paths and argument boundaries throughout.
- Clearly distinguishes checksum verification from unperformed SLSA
  provenance verification.

The primary `curl | bash` interface is retained for convenience. Documentation
also shows how to download, inspect, and then execute `install.sh` for users who
prefer that security posture.

## 11. Compatibility and dependencies

The generated installer and wrappers support Bash 3.2 or later so that the
default Bash shipped on older macOS installations remains usable. They avoid
associative arrays and features introduced by newer Bash releases.

Required host utilities are limited to Bash, `curl`, `uname`, `mktemp`,
`chmod`, `mv`, `ln`, and a SHA-256/SHA-384 checksum implementation available
on the target platform. Wari does not require system PHP, Composer, `jq`,
GitHub CLI, Docker, Homebrew, or a Linux package manager.

## 12. Testing strategy

### 12.1 Offline installer tests

Offline tests cover:

- Argument parsing and rejected unknown arguments.
- Version normalization and malicious/invalid input rejection.
- OS and architecture mappings.
- Static and GNU Linux asset selection.
- glibc validation for GNU builds.
- Exact asset and digest extraction from a recorded GitHub fixture.
- Checksum comparison and mismatch handling.
- Existing `.wari` or `wari` rejection before network access.
- Staging cleanup target validation.
- Interactive, `--yes`, and missing-TTY behavior.
- `-d value` and `-dvalue` compatibility filtering.
- Dispatcher help, unknown-command rejection, exact argument forwarding, and
  delegated exit-code propagation.

### 12.2 Offline wrapper integration tests

Tests use small fake executables instead of downloading FrankenPHP. They verify
working-directory behavior, preservation of spaces and argument boundaries,
exit-code and signal propagation, Composer environment injection, `serve`
public-directory checks, and confinement of writes to a temporary project.

### 12.3 Live smoke tests

An opt-in local test and CI job install real upstream artifacts and verify:

```bash
./wari php --version
./wari composer --version
./wari frankenphp version
./wari serve
```

The server test creates a temporary `public/index.php`, verifies that port 8000
is available, starts `./wari serve`, performs an HTTP request through the
loopback interface, and terminates the process cleanly. If port 8000 is already
occupied, the live test reports an environment failure rather than changing
the public `wari serve` contract.

The CI target matrix is:

- Ubuntu x86_64 with the static build.
- Ubuntu x86_64 with the GNU build.
- macOS ARM64.
- macOS x86_64 when a suitable runner is available.

ARM64 Linux mapping remains covered offline until a native or emulated live
runner is deliberately added.

## 13. Explicitly deferred scope

Wari v1 does not include:

- Windows, Git Bash, or WSL support.
- Independent PHP-version selection.
- Dynamic extension installation or building.
- Composer version pinning or self-update management.
- Compatibility with the old `./wari/<command>` directory interface.
- Updating, reinstalling, merging, or uninstalling an existing `.wari/` and
  `wari` installation.
- Production deployment, TLS, daemonization, or process supervision.
- A configurable convenience `serve` command.
- SLSA verification performed by Wari.
- Cross-project sharing of one Wari runtime.

These constraints keep v1 focused on a verifiable, project-local runtime with
a small public interface.
