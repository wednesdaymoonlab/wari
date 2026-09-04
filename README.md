# Wari

Wari installs a project-local PHP development runtime powered by the official
FrankenPHP standalone binary and Composer. It does not require PHP, Composer,
Docker, Homebrew, or a Linux package manager to be installed globally.

## Install

Run this command from the root of the PHP project:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
```

The installer is interactive even through a pipe because prompts read from
`/dev/tty`. For CI or another environment without a terminal, explicitly use
`--yes`:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | \
  bash -s -- --yes
```

Pin a stable FrankenPHP version or choose the GNU Linux build when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | \
  bash -s -- --yes --version 1.12.7 --linux-build gnu
```

To inspect the installer before execution:

```bash
curl -fsSLo wari-install.sh https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh
less wari-install.sh
bash wari-install.sh
```

The installer refuses to continue if either `./wari` or `./.wari` already
exists, including a symbolic link. It never updates, merges, or removes an
existing runtime.

FrankenPHP and Composer downloads show curl's ASCII progress bar when standard
error is connected to a terminal. CI runs and redirected output stay quiet while
still reporting download errors and retries.

## Use

```bash
./wari php --version
./wari php artisan migrate
./wari php -S 127.0.0.1:8000 -t public
./wari composer install
./wari composer require vendor/package
./wari serve
./wari frankenphp version
```

`./wari` is the public command dispatcher. The downloaded runtime, Composer,
manifest, and internal wrappers live in the adjacent hidden `.wari/` directory.
The earlier `./wari/php` directory interface is intentionally unsupported.

`./wari serve` is a local-development shortcut. It requires `./public`, binds
only to `127.0.0.1:8000`, and does not accept custom options. Use the transparent
wrapper for advanced commands:

```bash
./wari frankenphp php-server --listen 127.0.0.1:9000 --root ./public
./wari frankenphp run --config Caddyfile
```

The dispatcher locates `.wari/` relative to itself, so the whole project
remains relocatable. The PHP wrapper preserves its caller's working directory,
sets `PHP_BINARY` to itself, and prepends `.wari/` to `PATH`. Composer package
scripts and PHP programs that start child PHP processes therefore keep using
the same project-local runtime and can resolve relative paths such as
`artisan`.

FrankenPHP `php-cli` does not support every native PHP CLI option. Wari removes
`-d value` and `-dvalue` arguments so Composer remains compatible. Composer
child processes do this silently; direct `wari php` calls warn for each ignored
setting. Use `./wari php -m` to inspect extensions built into the selected
FrankenPHP binary. Wari v1 does not install extensions.

Wari translates PHP's common development-server form,
`php -S <address> [-t <document-root>] [router.php]`, to FrankenPHP's
`php-server`. The optional router is treated as a compatibility hint rather
than executed directly; FrankenPHP serves existing files and falls back to the
document root's `index.php`. Projects whose router contains custom behavior
beyond that front-controller pattern should use a project-specific Caddyfile
through `./wari frankenphp run --config Caddyfile`.

Some process managers remove `HOME` from server subprocesses. Wari keeps Caddy
data project-local under `.wari/runtime/xdg/` in that case. Caddy on macOS may
still print a harmless `$HOME is not defined` configuration-directory warning;
Wari does not invent or overwrite a home directory.

## Supported platforms

| Operating system | Architecture | Build |
| --- | --- | --- |
| Linux | x86_64 | fully static (default) or GNU/glibc |
| Linux | ARM64 | fully static (default) or GNU/glibc |
| macOS | Intel | official standalone binary |
| macOS | Apple Silicon | official standalone binary |

Windows, Git Bash, and WSL are not officially supported in v1. The GNU Linux
option requires glibc; choose the fully static build for maximum portability.

## Verification and security

Wari downloads only from the official GitHub, FrankenPHP, and Composer hosts.
It verifies FrankenPHP against the SHA-256 digest in GitHub release metadata and
verifies the Composer installer against Composer's published SHA-384 checksum.
There is no option to skip verification.

`.wari/manifest.json` records exact versions, platform, artifact URL, SHA-256,
installation time, and verification status. Checksum verification does not
prove build provenance, so Wari truthfully records `slsa_verified: false`.
If GitHub CLI is already available, provenance can be checked manually:

```bash
gh attestation verify ./.wari/runtime/frankenphp --owner php
```

GitHub CLI is optional and is never installed or invoked by Wari.

## Troubleshooting

- GitHub API rate limit: wait for the unauthenticated limit to reset, then run
  the installer again. Wari will not fall back to an unverified download.
- `./wari` or `./.wari` already exists: inspect the path and move or remove it
  yourself, then run the installer again. A power loss or `SIGKILL` during the
  two-path publication step can leave a complete `.wari/` without `wari`; Wari
  stops rather than overwriting that partial installation.
- Composer reports a missing `ext-*`: the official static binary does not
  include that extension; Wari v1 cannot add it.
- macOS blocks execution: review the downloaded artifact and local Gatekeeper
  policy. Wari does not disable quarantine or system security controls.

## Development

Run offline tests:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
```

Run the opt-in test that downloads real artifacts and starts a loopback server:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

## License

Wari-authored source is available under the MIT License. Downloaded FrankenPHP
and Composer artifacts retain their upstream licenses.
