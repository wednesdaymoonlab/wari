# Wari

Wari installs a project-local PHP development runtime powered by the official
FrankenPHP standalone binary and Composer. It does not require PHP, Composer,
Docker, Homebrew, or a Linux package manager to be installed globally.

## Add Wari to a project

Run the initializer from the project root:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
```

The initializer downloads the portable `wari` launcher from an exact Wari Git
tag, generates the version/checksum policy in `wari.lock` from official
FrankenPHP and Composer metadata, and adds a managed block in `.gitignore`.
It does not download PHP or Composer binaries. `./wari setup` explicitly
creates the machine-specific runtime in ignored `.wari/`.

Commit `wari`, `wari.lock`, and `.gitignore`. Do not commit `.wari/`. Teammates
on Linux, Intel macOS, and Apple Silicon macOS share the same tracked launcher
and lock, while each machine downloads its matching locked runtime.

For CI or another environment without a terminal, pass `--yes` to setup:

```bash
./wari setup --yes
```

To inspect the initializer before execution:

```bash
curl -fsSLo wari-install.sh https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh
less wari-install.sh
bash wari-install.sh
```

The initializer refuses to overwrite an existing `wari` or `wari.lock`.
Existing installations from the older linked-launcher layout can opt into the
strict migration path with `bash install.sh --migrate`; it preserves the old
runtime, installs the tracked pair, and then requires `./wari setup`.

Pin runtime dependencies during initialization when needed:

```bash
bash wari-install.sh \
  --frankenphp 1.12.7 \
  --composer 2.8.11 \
  --linux-build static
```

Without exact dependency options, the initializer selects the latest stable
FrankenPHP and Composer releases. Linux defaults to the fully static build.

### Clone and CI workflow

After cloning a project that already tracks Wari:

```bash
git clone <repository>
cd <repository>
./wari setup
./wari composer install
```

CI uses the same lock and must not run `./wari update`:

```bash
./wari setup --yes
./wari composer install --no-interaction
```

If `./wari php`, `./wari composer`, `./wari serve`, `./wari frankenphp`,
`./wari create-project`, or `./wari service` is run before setup—or after the
lock/platform changes—Wari exits with a message telling the user to run
`./wari setup`. It never downloads or repairs the runtime as a side effect of
another command.

### Create a new Composer project

Start with an empty directory, install Wari, then ask the bundled Composer to
create the project in that directory:

```bash
mkdir php-app
cd php-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
./wari create-project vendor/project
```

Replace `vendor/project` with the Composer package to create. Wari displays the
full destination path and asks for confirmation before downloading anything.
At that point, the directory may contain only `wari`, `wari.lock`, `.wari/`,
and `.gitignore`. For this bootstrap-only flow, `.gitignore` must still contain
exactly Wari's managed block; add custom ignore rules after project creation.

For automation, `--yes` skips Wari's confirmation. Composer interaction is
controlled separately with Composer's `--no-interaction` option:

```bash
./wari create-project --yes vendor/project --no-interaction
```

Composer works in a temporary sibling directory so it receives an empty target.
After a successful installation, Wari moves the completed project into the
current directory. A failed installation removes the staged project and leaves
the local Wari runtime unchanged.

FrankenPHP and Composer downloads show curl's ASCII progress bar when standard
error is connected to a terminal. CI runs and redirected output stay quiet while
still reporting download errors and retries.

## Use

```bash
./wari php --version
./wari php script.php
./wari php -S 127.0.0.1:8000 -t public
./wari composer install
./wari composer require vendor/package
./wari serve
./wari frankenphp version
./wari service --help
```

`./wari` is the public command dispatcher. The downloaded runtime, Composer,
manifest, and internal wrappers live in the adjacent hidden `.wari/` directory.
The earlier `./wari/php` directory interface is intentionally unsupported.

Update the locked FrankenPHP and Composer dependencies intentionally:

```bash
./wari update
git diff -- wari.lock
./wari setup
```

With no version options, both dependencies move to their latest stable
releases. An exact override may be supplied for either dependency; the omitted
dependency still resolves latest stable:

```bash
./wari update --frankenphp 1.12.7 --composer 2.10.3
./wari update --linux-build gnu
```

`update` replaces only `wari.lock` and preserves the current Linux build unless
overridden. It never changes the launcher, `.wari/`, Composer application
dependencies, Git history, or remotes.

Update the Wari launcher separately from an exact immutable Git tag:

```bash
./wari self-update 0.3.0
git diff -- wari wari.lock
./wari setup
```

`self-update` preserves the exact locked FrankenPHP and Composer versions,
refreshes their official checksum metadata, and leaves `.wari/` untouched.
Both update commands make the existing runtime stale through the changed lock,
so setup remains an explicit review step.

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
`scripts/task.php`.

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

## Production services

Wari can generate a complete systemd unit on Linux or a Supervisor program on
Linux and macOS. It prints configuration to standard output and review/install
instructions to standard error; it never installs a service or invokes `sudo`.

For a broadly compatible front-controller application:

```bash
./wari service generate systemd \
  --profile=classic --user=www-data >my-app.service
```

For Supervisor, replace `systemd` with `supervisor` and redirect to a `.conf`
file. Laravel applications deliberately configured for long-lived workers can
choose `--profile=octane`; projects that own their routing can choose
`--profile=caddyfile --config=Caddyfile`. Generated application listeners are
loopback-only and are intended to sit behind an independently configured Nginx,
Apache, Caddy, or other reverse proxy.

See the [production guide](docs/production/README.md) for profile selection,
installation, logging, reload/restart, update, and removal procedures.

## Supported platforms

| Operating system | Architecture | Build |
| --- | --- | --- |
| Linux | x86_64 | fully static (default) or GNU/glibc |
| Linux | ARM64 | fully static (default) or GNU/glibc |
| macOS | Intel | official standalone binary |
| macOS | Apple Silicon | official standalone binary |

Windows, Git Bash, and WSL are not officially supported in v1. The GNU Linux
option requires glibc; choose the fully static build for maximum portability.

## Framework and CMS compatibility

See the [compatibility guides](docs/compatibility/README.md) for the versions,
commands, test results, and known limitations recorded while running Laravel,
Symfony, WordPress, CodeIgniter, Slim, and CakePHP with Wari.

## Verification and security

Wari downloads only from the official GitHub, FrankenPHP, and Composer hosts.
The initializer obtains the launcher over HTTPS from an exact semantic-version
Git tag, validates its embedded version, and records its calculated SHA-256 in
the generated lock. Protect published version tags from deletion or movement;
the initial download trust boundary is GitHub HTTPS and repository access
control, not a separately signed release artifact.

`wari.lock` pins exact Wari, FrankenPHP, Composer, platform artifact, and
checksum values. Setup verifies the FrankenPHP artifact, Composer installer,
and installed Composer PHAR against the committed lock. There is no option to
skip verification.

`.wari/.wari-owned` and `.wari/manifest.json` jointly identify a runtime that
Wari may safely replace or clean up. The manifest records exact versions,
platform, artifact URL, SHA-256, installation time, and verification status.
Checksum verification does not
prove build provenance, so Wari truthfully records `slsa_verified: false`.
If GitHub CLI is already available, provenance can be checked manually:

```bash
gh attestation verify ./.wari/runtime/frankenphp --owner php
```

GitHub CLI is optional and is never installed or invoked by Wari.

## Troubleshooting

- Runtime is missing, stale, or for another platform: run `./wari setup`.
- GitHub API rate limit: wait for the unauthenticated limit to reset, then retry
  lock generation, initialization, or dependency update. Wari never falls back
  to an unverified download.
- `.wari/` exists but is not recognized: inspect it manually. Setup refuses to
  move or delete a directory it cannot prove belongs to Wari.
- `wari` does not match `wari.lock`: restore the tracked pair from Git or review
  the local edit. Wari will not execute a launcher/lock pair with a bad digest.
- `./wari create-project` reports an unsupported entry: move the entry out of
  the directory and retry. New-project creation intentionally accepts only the
  four supported bootstrap entries: `wari`, `wari.lock`, `.wari/`, and
  `.gitignore`.
- Composer reports a missing `ext-*`: the official static binary does not
  include that extension; Wari v1 cannot add it.
- macOS blocks execution: review the downloaded artifact and local Gatekeeper
  policy. Wari does not disable quarantine or system security controls.

## Development

Initialize a test project from the current working source before a matching Git
tag exists:

```bash
bash ../../core/install.sh --local-source ../../core
```

Publishing a Wari version requires pushing the tested source commit and then a
matching immutable tag such as `v0.3.0`. A GitHub Release is optional; the
initializer does not consume Release assets.

Run offline tests:

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

Run the opt-in test that downloads real artifacts and starts a loopback server:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

## License

Wari-authored source is available under the MIT License. Downloaded FrankenPHP
and Composer artifacts retain their upstream licenses.
