# Wari Portable PHP Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Bash installer that creates a verified, hidden project-local FrankenPHP and Composer runtime and exposes it through one `./wari <command>` dispatcher.

**Architecture:** `install.sh` is both the distributable installer and a sourceable library of focused Bash functions guarded by a `main` check. It resolves official GitHub release metadata, builds and verifies the runtime in staging, publishes that directory as `.wari/`, and publishes the root `wari` dispatcher last. Internal wrappers remain in `.wari/` for Composer child-process compatibility; offline tests exercise the dispatcher and transaction cleanup, while an opt-in test downloads real artifacts.

**Tech Stack:** Bash 3.2+, curl, POSIX userland tools, SHA-256/SHA-384 utilities, FrankenPHP standalone binary, Composer installer, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-04-wari-portable-php-runtime-design.md`

## Global Constraints

- Support Linux x86_64/ARM64 and macOS Intel/Apple Silicon only.
- Linux defaults to the fully static build; GNU builds require detected glibc.
- PHP is the version embedded in FrankenPHP; do not offer an independent PHP version.
- Composer is latest stable; do not implement Composer pinning or self-update.
- Do not require system PHP, Composer, jq, GitHub CLI, Docker, sudo, or a package manager.
- Read interactive input from `/dev/tty`; noninteractive installation requires `--yes`.
- Stop before network access if either `./wari` or `./.wari` exists, including a symbolic link, and never overwrite either path.
- Verify every FrankenPHP SHA-256 digest and the Composer installer SHA-384 checksum; there is no verification bypass.
- Keep the public `serve` command fixed at `127.0.0.1:8000` with `<project>/public` as root.
- Support Bash 3.2; do not use associative arrays, `mapfile`, namerefs, or `${value,,}`.
- Never run `git add`, `git commit`, or `git push`; leave every change unstaged for user review.

## Revision note

Tasks 1-6 describe the implemented baseline and retain its original
`./wari/<command>` examples for historical context. Task 7 is the only pending
implementation work and supersedes every earlier final-layout, invocation,
preflight, publication, smoke-test, and documentation path. The approved final
public interface is exclusively `./wari <command>` with runtime state in
`./.wari/`.

## File map

- `install.sh`: Installer entry point, release resolution, verification, atomic staging, wrapper generation, and manifest generation.
- `tests/test-helper.sh`: Dependency-free test runner, assertions, temporary-directory lifecycle, and test summary.
- `tests/test-installer.sh`: Offline tests for arguments, platform mapping, release parsing, checksum verification, TTY policy, and cleanup safety.
- `tests/test-wrappers.sh`: Offline integration tests for generated wrappers using a fake FrankenPHP executable.
- `tests/fixtures/frankenphp-release.json`: Minimal representative GitHub release response containing supported assets, digests, and misleading similarly named assets.
- `tests/test-live-install.sh`: Explicitly opt-in test using real upstream downloads and a local HTTP request.
- `.github/workflows/test.yml`: Ubuntu/macOS offline matrix plus controlled live smoke jobs.
- `README.md`: Installation, security, usage, limitations, and manual verification documentation.
- `LICENSE`: MIT license text.
- `.gitignore`: Local editor/test residue only; `playground/` is already outside this repository.

---

### Task 1: Test harness, CLI parsing, and platform selection

**Files:**

- Create: `tests/test-helper.sh`
- Create: `tests/test-installer.sh`
- Create: `install.sh`

**Interfaces:**

- Produces: `die(message)`, `normalize_version(value)`, `parse_args(args...)`, `detect_platform(os, arch, linux_build)`, `has_glibc()`, and globals `ASSUME_YES`, `REQUESTED_VERSION`, `LINUX_BUILD`, `PLATFORM_OS`, `PLATFORM_ARCH`, `ASSET_NAME`.
- Consumes: No project code; only Bash 3.2 and standard commands.

- [ ] **Step 1: Create the dependency-free test harness**

Implement `tests/test-helper.sh` with these concrete helpers:

```bash
#!/usr/bin/env bash
set -u

TESTS_RUN=0
TESTS_FAILED=0

fail() { printf 'not ok - %s\n' "$1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then pass "$message"; else
    fail "$message (expected: $expected, actual: $actual)"
  fi
}
assert_fails() {
  local message="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if ( "$@" >/dev/null 2>&1 ); then fail "$message"; else pass "$message"; fi
}
finish_tests() {
  printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
```

- [ ] **Step 2: Write failing argument and platform tests**

In `tests/test-installer.sh`, source the helper and `../install.sh`, reset globals before each parse, and assert:

```bash
assert_eq 'v1.12.7' "$(normalize_version 1.12.7)" 'adds v prefix'
assert_eq 'v1.12.7' "$(normalize_version v1.12.7)" 'keeps v prefix'
assert_fails 'rejects shell input in version' normalize_version '1.2.3;touch bad'

detect_platform Linux x86_64 static
assert_eq 'frankenphp-linux-x86_64' "$ASSET_NAME" 'maps Linux x86 static'
detect_platform Linux aarch64 gnu
assert_eq 'frankenphp-linux-aarch64-gnu' "$ASSET_NAME" 'maps Linux ARM GNU'
detect_platform Darwin arm64 static
assert_eq 'frankenphp-mac-arm64' "$ASSET_NAME" 'maps Apple Silicon'
assert_fails 'rejects Windows' detect_platform MINGW64_NT-10.0 x86_64 static
assert_fails 'rejects RISC-V' detect_platform Linux riscv64 static
```

Also test `--yes`, `--version`, `--linux-build`, `--help`, missing option values, and unknown options.

- [ ] **Step 3: Run the tests and verify the expected failure**

Run:

```bash
bash tests/test-installer.sh
```

Expected: failure because `install.sh` and its functions do not exist.

- [ ] **Step 4: Implement the minimal installer skeleton and pure functions**

Create `install.sh` with `#!/usr/bin/env bash`, `set -Eeuo pipefail`, constants for Wari version and official hosts, stderr helpers, strict numeric semantic-version validation (`^v?[0-9]+\.[0-9]+\.[0-9]+$`), argument parsing, and exact platform mappings from the spec. Keep `--help` successful without starting installation.

Use this entry guard so tests can source functions safely:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

`detect_platform` must normalize `amd64` to x86_64 and both `arm64` and `aarch64` to ARM64. On macOS, reject `--linux-build gnu` rather than silently ignoring it. `has_glibc` first tries `getconf GNU_LIBC_VERSION`, then checks `ldd --version` output for `glibc` or `GNU libc`.

- [ ] **Step 5: Run Task 1 tests on the available Bash versions**

Run:

```bash
bash tests/test-installer.sh
```

Expected: all Task 1 tests pass. If `bash3` is installed locally, also run `bash3 tests/test-installer.sh`; otherwise Bash 3.2 compatibility is enforced later on macOS CI.

- [ ] **Step 6: User review checkpoint**

Show `git diff -- install.sh tests/test-helper.sh tests/test-installer.sh` and stop for review if requested. Do not stage or commit.

---

### Task 2: Official release metadata and checksum verification

**Files:**

- Create: `tests/fixtures/frankenphp-release.json`
- Modify: `tests/test-installer.sh`
- Modify: `install.sh`

**Interfaces:**

- Consumes: `normalize_version`, `ASSET_NAME`, constants `FRANKENPHP_API_BASE` and `FRANKENPHP_DOWNLOAD_HOST`.
- Produces: `fetch_release_json(version, destination)`, `parse_release(json_file, asset_name)`, globals `RESOLVED_TAG`, `ASSET_URL`, `ASSET_SHA256`, `download_file(url, destination)`, `calculate_checksum(algorithm, file)`, and `verify_checksum(algorithm, expected, file)`.

- [ ] **Step 1: Add a minimal release fixture**

Create a JSON fixture with `tag_name: v1.12.7`, `draft: false`, `prerelease: false`, exact assets `frankenphp-linux-x86_64`, `frankenphp-linux-x86_64-gnu`, `frankenphp-linux-aarch64`, `frankenphp-linux-aarch64-gnu`, `frankenphp-mac-x86_64`, and `frankenphp-mac-arm64`. Give each a distinct 64-character lowercase digest and official `browser_download_url`. Include `frankenphp-linux-x86_64-debug` to prove selection is exact rather than prefix-based.

- [ ] **Step 2: Write failing metadata and checksum tests**

Add tests that call `parse_release` and assert the exact tag, URL, and digest. Create modified fixture copies and assert failure for `draft: true`, `prerelease: true`, a missing digest, a `sha512:` digest, duplicate exact asset names, and an asset URL whose host is not `github.com`.

Create a file containing `wari-checksum-test\n`, calculate SHA-256/SHA-384 with the implementation-selected utility, assert valid checksums pass, and assert a one-character mismatch fails.

- [ ] **Step 3: Run tests and verify they fail for missing functions**

Run `bash tests/test-installer.sh`.

Expected: existing tests pass; new release/checksum tests fail because the functions are undefined.

- [ ] **Step 4: Implement release fetching and strict parsing**

`fetch_release_json latest FILE` calls `GET /repos/php/frankenphp/releases/latest`; a pinned tag calls `GET /repos/php/frankenphp/releases/tags/vX.Y.Z`. Use:

```bash
curl --fail --show-error --silent --location \
  --retry 3 --connect-timeout 15 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$url" -o "$destination"
```

Implement the fixture-tested parser with POSIX `awk`: locate exactly one top-level asset `"name"` line, then capture its subsequent `digest` and `browser_download_url` fields. Separately require exactly one `tag_name`, and literal top-level `draft: false` and `prerelease: false`. Reject fields containing tabs/newlines and require the URL prefix `https://github.com/php/frankenphp/releases/download/$RESOLVED_TAG/`.

- [ ] **Step 5: Implement portable checksum calculation**

For SHA-256 prefer `sha256sum`, then `shasum -a 256`. For SHA-384 prefer `sha384sum`, then `shasum -a 384`. Normalize output to lowercase hex and require exact lengths of 64 and 96 characters. Compare with `[[ "$actual" == "$expected" ]]`; never use a partial match.

- [ ] **Step 6: Run all offline installer tests**

Run `bash tests/test-installer.sh`.

Expected: all tests pass without network access.

- [ ] **Step 7: User review checkpoint**

Show the fixture and parser diff, emphasizing that JSON parsing is intentionally constrained to GitHub's pretty-printed release response. Do not stage or commit.

---

### Task 3: Interactive policy and atomic artifact installation

**Files:**

- Modify: `tests/test-installer.sh`
- Modify: `install.sh`

**Interfaces:**

- Consumes: parsed CLI globals, platform globals, release globals, `download_file`, and `verify_checksum`.
- Produces: `open_terminal()`, `prompt_choice(prompt, default)`, `confirm_install()`, `create_staging(project_root)`, `is_safe_staging_path(project_root, path)`, `cleanup()`, `install_frankenphp(staging)`, and `install_composer(staging)`.

- [ ] **Step 1: Write failing prompt and staging-safety tests**

Use temporary files as fd 3 input and fd 4 output. Assert blank input selects the default, `2` selects the custom/GNU option, invalid input repeats the prompt, and confirmation accepts `y`, `Y`, or blank while rejecting `n`.

Assert safe cleanup accepts only `<project>/.wari-install.XXXXXX` and rejects `/`, the project root, `<project>/wari`, `<project>/.wari-install.`, and a similarly named path in another directory. Test that an existing `<project>/wari` is rejected before a mocked `curl` can record a call.

- [ ] **Step 2: Run tests and verify the new cases fail**

Run `bash tests/test-installer.sh`.

Expected: failures name the missing terminal and staging functions.

- [ ] **Step 3: Implement terminal and noninteractive behavior**

`open_terminal` opens fd 3 from `/dev/tty` and fd 4 to `/dev/tty`. With `--yes`, skip opening the terminal and use defaults unless flags override them. Without `--yes`, failure to open the terminal is fatal and prints the exact automation example from the spec.

Interactive mode offers latest or a validated explicit version, then on Linux static or GNU, then one final confirmation. A negative confirmation exits successfully without creating staging.

- [ ] **Step 4: Implement guarded staging and cleanup**

Capture `PROJECT_ROOT="$(pwd -P)"`; reject `PROJECT_ROOT/wari`; create staging with `mktemp -d "$PROJECT_ROOT/.wari-install.XXXXXX"`; install traps for `EXIT INT TERM HUP`. The trap calls `is_safe_staging_path` before `rm -rf -- "$STAGING_DIR"`. Clear `STAGING_DIR` immediately after the successful `mv -- "$staging" "$PROJECT_ROOT/wari"`.

- [ ] **Step 5: Implement artifact installation with mockable boundaries**

`install_frankenphp` downloads to `runtime/frankenphp.download`, verifies the API digest, renames it to `runtime/frankenphp`, and applies mode 0755.

`install_composer` downloads:

```text
https://getcomposer.org/installer
https://composer.github.io/installer.sig
```

Trim whitespace from `installer.sig`, verify the installer SHA-384, then execute:

```bash
"$staging/runtime/frankenphp" php-cli "$staging/composer-setup.php" \
  --quiet --install-dir="$staging/runtime" --filename=composer.phar
```

Delete only `composer-setup.php` and its checksum after successful creation of `composer.phar`. Make download and execution commands overrideable in tests through shell functions, not environment-provided command strings and never `eval`.

- [ ] **Step 6: Add mocked failure-path tests**

Test failure during FrankenPHP download, FrankenPHP verification, Composer download, Composer verification, Composer execution, and final smoke checks. Each test must assert there is no final `wari/` and no `.wari-install.*` residue. Add a success test asserting one final `wari/` and no staging directory.

- [ ] **Step 7: Run offline tests**

Run `bash tests/test-installer.sh`.

Expected: all tests pass and make no network requests.

- [ ] **Step 8: User review checkpoint**

Show `git diff` for Task 3. Do not stage or commit.

---

### Task 4: Generate project-bound wrappers

**Files:**

- Create: `tests/test-wrappers.sh`
- Modify: `install.sh`

**Interfaces:**

- Consumes: a staging directory containing executable `runtime/frankenphp` and `runtime/composer.phar`.
- Produces: `generate_wrappers(staging)` and executable `php`, `composer`, `serve`, and `frankenphp` files.

- [ ] **Step 1: Write the fake FrankenPHP test double**

In `tests/test-wrappers.sh`, create a temporary project and a fake `runtime/frankenphp` that writes its current directory, argument count, each argument on its own numbered line, `PHP_BINARY`, and `PATH` to a capture file. It returns the numeric value supplied through a test-only `FAKE_EXIT_CODE` environment variable.

- [ ] **Step 2: Write failing PHP-wrapper tests**

Generate wrappers, invoke `php` from a nested directory, and assert the fake process runs in the project root. Pass arguments containing spaces and glob characters and assert exact boundaries. Verify both forms below remove only the intended settings and retain `script.php`:

```bash
wari/php -d memory_limit=-1 script.php
wari/php -dmemory_limit=-1 script.php
```

Assert warnings name `memory_limit=-1`, a bare `-d` exits nonzero, and a fake exit status of 17 is returned as 17.

- [ ] **Step 3: Write failing Composer, serve, and raw-wrapper tests**

Assert Composer invokes `php-cli`, then the absolute `composer.phar`, then user arguments; `PHP_BINARY` equals the absolute public PHP wrapper; and `PATH` starts with the absolute `wari/` directory.

Assert `serve` fails before execution when `public/` is absent. With `public/` present, assert exact arguments `php-server --listen 127.0.0.1:8000 --root <absolute-public-path>`. Assert the raw wrapper forwards `run --config 'My Caddyfile'` unchanged from project root.

- [ ] **Step 4: Run wrapper tests and verify they fail**

Run `bash tests/test-wrappers.sh`.

Expected: failures because `generate_wrappers` is missing.

- [ ] **Step 5: Implement wrapper templates**

Generate each wrapper using a single-quoted heredoc so installation-time shell expansion cannot corrupt `$@`, `$PATH`, or paths. Every generated file begins with Bash strict mode and resolves:

```bash
WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$WARI_DIR")"
cd -- "$PROJECT_ROOT"
```

The PHP wrapper iterates over a normal indexed array, filters `-d` pairs or joined `-dVALUE`, and writes warnings to stderr. Generate `runtime/php-proxy.php` and route `--version`/`-v`, `-r`, `-m`, and `-i` through helper modes `version`, `eval`, `modules`, and `info`. Normal script paths finish with:

```bash
exec "$WARI_DIR/runtime/frankenphp" php-cli "${filtered_args[@]}"
```

Composer exports absolute `PHP_BINARY` and prepends Wari to `PATH`, then executes `"$WARI_DIR/php" "$WARI_DIR/runtime/composer.phar" "$@"`. `serve` checks `[[ -d "$PROJECT_ROOT/public" ]]`. The raw wrapper directly executes the runtime binary. Apply mode 0755 to all four wrappers.

- [ ] **Step 6: Run both offline suites**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
```

Expected: all tests pass.

- [ ] **Step 7: User review checkpoint**

Show the generated wrapper templates and test output. Do not stage or commit.

---

### Task 5: Manifest, smoke checks, and end-to-end main flow

**Files:**

- Modify: `tests/test-installer.sh`
- Modify: `install.sh`

**Interfaces:**

- Consumes: installed staging runtime, resolved release metadata, platform globals, and wrapper generation.
- Produces: `json_escape(value)`, `detect_installed_versions(staging)`, `write_manifest(staging)`, `run_smoke_checks(staging)`, and complete `main(args...)`.

- [ ] **Step 1: Write failing manifest tests**

Stub version output as:

```text
PHP 8.5.3 (cli) (built: ...)
FrankenPHP v1.12.7 PHP 8.5.3 Caddy v2.10.2
Composer version 2.8.12 2025-04-08 13:03:14
```

Assert the generated JSON contains exact Wari, FrankenPHP, PHP, Composer, OS, architecture, Linux-build, asset, URL, digest, boolean verification fields, and a UTC timestamp. Validate the file using staged PHP:

```bash
wari/php -r '$d=json_decode(file_get_contents("wari/manifest.json"), true, 512, JSON_THROW_ON_ERROR); exit(is_array($d) ? 0 : 1);'
```

Also test JSON escaping for quotes, backslashes, tabs, carriage returns, and newlines.

- [ ] **Step 2: Write failing full-flow tests with mocked network**

Run `main --yes --version 1.12.7 --linux-build static` in a temporary Linux x86_64 project with mocked platform and downloads. Assert the final layout, executable modes, absence of staging, expected manifest, and success instructions. Assert `--help` and declined confirmation create nothing.

- [ ] **Step 3: Run tests and verify failures**

Run `bash tests/test-installer.sh`.

Expected: failures identify missing manifest, version detection, smoke check, and complete orchestration functions.

- [ ] **Step 4: Implement version discovery and JSON generation**

Extract PHP's first `PHP X.Y.Z` token from `php --version`, FrankenPHP's `vX.Y.Z` token from `frankenphp version`, and Composer's first semantic version from `composer --version`. Reject empty or malformed results. Implement JSON escaping in Bash and emit deterministic key order with booleans unquoted and `linux_build` as JSON `null` on macOS.

- [ ] **Step 5: Implement smoke checks**

Before final rename, run the staged equivalents of:

```bash
php --version
composer --version
frankenphp version
php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' \
  "$staging/manifest.json"
```

Do not start a server during installation. Capture output needed for the manifest and suppress only redundant successful output, never errors.

- [ ] **Step 6: Complete `main` orchestration**

Order operations exactly as the spec: parse, preflight, reject existing destination, detect platform, acquire choices, validate GNU/glibc, confirm, resolve metadata, stage, download and verify, generate wrappers, discover versions, write manifest, smoke-test, atomically rename, clear traps, and print commands. Ensure no prompt or network call occurs for `--help`.

- [ ] **Step 7: Run all offline tests and ShellCheck if available**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
```

Expected: all pass. If `shellcheck` exists, run `shellcheck -s bash install.sh tests/*.sh`; treat findings as failures but do not make ShellCheck a user dependency.

- [ ] **Step 8: User review checkpoint**

Provide `git diff --stat`, the full test summary, and any unavailable optional checks. Do not stage or commit.

---

### Task 6: Live verification, CI, documentation, and licensing

**Files:**

- Create: `tests/test-live-install.sh`
- Create: `.github/workflows/test.yml`
- Create: `README.md`
- Create: `LICENSE`
- Create: `.gitignore`

**Interfaces:**

- Consumes: completed `install.sh` and generated public commands.
- Produces: documented user workflow and automated cross-platform verification.

- [ ] **Step 1: Write the opt-in live test**

Require `WARI_RUN_LIVE=1`; otherwise print `live test skipped` and exit 0. Create a temporary project, copy `install.sh`, run it with `--yes --linux-build "${WARI_LINUX_BUILD:-static}"`, assert all four commands and manifest exist, then run PHP, Composer, and FrankenPHP version commands.

Create `public/index.php` containing `<?php echo "wari-live-ok";`, first fail clearly if `127.0.0.1:8000` is occupied, start `./wari/serve` in the background, poll with `curl` for at most 20 seconds, require the exact body `wari-live-ok`, and terminate/wait for the recorded PID in a trap. Remove only the test's `mktemp` directory.

- [ ] **Step 2: Run the live test manually in `playground/`**

Run from the repository root:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

Expected: one real download, verified installation, three version checks, and a successful loopback HTTP response. This can download roughly 200 MB; report the observed size and duration.

- [ ] **Step 3: Add GitHub Actions**

Create offline jobs on `ubuntu-latest`, `macos-14` (ARM64 when GitHub labels provide it), and an available Intel macOS label. Each runs both offline suites. Add live jobs with concurrency controls and a timeout, covering Ubuntu static, Ubuntu GNU, and supported macOS architectures. If GitHub does not expose an architecture under the repository's plan, keep that architecture in the offline matrix and document the missing live runner instead of pretending it ran.

- [ ] **Step 4: Add the MIT license**

Use the canonical MIT text with:

```text
Copyright (c) 2026 Wednesdays Moon Lab
```

- [ ] **Step 5: Write README usage and security documentation**

Document the exact raw GitHub install URL, download-before-execute alternative, interactive prompts, automation flags, supported platform matrix, Linux build choice, all four wrapper commands, fixed development-server behavior, Composer child-process PATH behavior, ignored `-d` warning, existing-directory refusal, extension limitations, checksum versus SLSA status, manifest fields, and troubleshooting for GitHub rate limits and macOS execution failures.

Include the optional provenance command without executing it:

```bash
gh attestation verify ./wari/runtime/frankenphp --owner php
```

State clearly that GitHub CLI is optional and Wari reports `slsa_verified: false`.

- [ ] **Step 6: Run the complete verification matrix available locally**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

Expected: all offline and live tests pass. Also run `git diff --check` and confirm `git status --short` shows only unstaged/untracked implementation files; do not stage them.

- [ ] **Step 7: Final user review handoff**

Report exact commands and results, supported platform checks actually exercised, untested matrix entries, live download version/digest, and all changed files. Leave Git staging empty and do not commit or push; the user performs all Git operations.

---

### Task 7: Hidden runtime and root command dispatcher

**Files:**

- Modify: `install.sh`
- Modify: `tests/test-installer.sh`
- Modify: `tests/test-wrappers.sh`
- Modify: `tests/test-live-install.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-04-wari-portable-php-runtime-design.md`

**Interfaces:**

- Consumes: existing `generate_wrappers(wari_dir)`, `run_smoke_checks(wari_dir)`, staging safety functions, and wrapper contracts.
- Produces: `generate_dispatcher(wari_dir)`, `publish_install(staging, project_root)`, `run_public_smoke_checks(project_root)`, globals `PUBLISHED_RUNTIME` and `PUBLISHED_DISPATCHER`, hidden runtime `<project>/.wari/`, and executable dispatcher `<project>/wari`.
- Public commands: `./wari php`, `./wari composer`, `./wari serve`, `./wari frankenphp`, `./wari help`, `./wari --help`, and `./wari -h`.
- Breaking change: remove support and documentation for `./wari/php`, `./wari/composer`, `./wari/serve`, and `./wari/frankenphp`.

- [x] **Step 1: Write failing destination-preflight tests**

Extend `tests/test-installer.sh` with table-driven temporary-project cases that
prove `preflight_project` rejects each path before a mocked network function can
run:

```text
<project>/wari           regular file
<project>/wari           symbolic link, including a broken link
<project>/.wari          directory
<project>/.wari          symbolic link, including a broken link
```

Use both `[[ -e "$path" ]]` and `[[ -L "$path" ]]` in test setup assertions so
broken links are genuinely covered. Add one empty-project case that succeeds.

- [x] **Step 2: Run the installer suite and verify RED**

Run:

```bash
/bin/bash tests/test-installer.sh
```

Expected: the `.wari` and broken-symbolic-link cases fail because the current
preflight checks only `-e "$project_root/wari"`.

- [x] **Step 3: Implement dual-path preflight**

Update `preflight_project(project_root)` to loop over the two exact candidates
`$project_root/.wari` and `$project_root/wari`. Reject a candidate when either
`-e` or `-L` succeeds, print the exact conflicting path, and return before
release resolution or download. Do not remove, merge, or modify either path.

- [x] **Step 4: Run the installer suite and verify GREEN**

Run `/bin/bash tests/test-installer.sh`.

Expected: all tests pass with zero failures.

- [x] **Step 5: Write failing dispatcher behavior tests**

Extend `tests/test-wrappers.sh` to create `<project>/.wari/runtime/frankenphp`,
call `generate_wrappers "$project/.wari"`, call
`generate_dispatcher "$project/.wari"`, and move the generated
`$project/.wari/wari` file to `$project/wari` to model publication. Assert:

```bash
./wari php -r 'echo "hello";' 'argument with spaces'
./wari composer require vendor/package
./wari serve
./wari frankenphp run --config 'My Caddyfile'
```

Each command must preserve current working-directory behavior, exact argument
boundaries, and the delegated exit status. Also assert:

- no argument, `help`, `--help`, and `-h` print the four command names and exit 0;
- an unknown command prints `Unknown Wari command: unknown`, prints usage to
  standard error, does not invoke FrankenPHP, and exits nonzero;
- a missing adjacent `.wari/` prints a clear error and exits nonzero;
- Composer exports `PHP_BINARY=<project>/.wari/php` and prepends
  `<project>/.wari` to `PATH`.

- [x] **Step 6: Run the wrapper suite and verify RED**

Run:

```bash
/bin/bash tests/test-wrappers.sh
```

Expected: failure because `generate_dispatcher` does not exist and the public
root command is not generated.

- [x] **Step 7: Implement the dispatcher generator**

Add `generate_dispatcher(wari_dir)` to `install.sh`. It writes
`$wari_dir/wari` with a single-quoted heredoc and mode 0755. The generated Bash
3.2-compatible script must:

```bash
WARI_PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WARI_RUNTIME_DIR="$WARI_PROJECT_ROOT/.wari"
```

Check that `$WARI_RUNTIME_DIR` is a directory, read `${1-}` without violating
`set -u`, and dispatch with an exact `case`:

```text
php          -> exec "$WARI_RUNTIME_DIR/php" "$@"
composer     -> exec "$WARI_RUNTIME_DIR/composer" "$@"
serve        -> exec "$WARI_RUNTIME_DIR/serve" "$@"
frankenphp   -> exec "$WARI_RUNTIME_DIR/frankenphp" "$@"
```

Shift once before each `exec`. Help variants and no argument print usage and
exit 0. Any other value prints the unknown-command error and usage to standard
error and exits 1. Do not use `eval`, command strings, or persistent `PATH`
changes.

- [x] **Step 8: Run both offline suites and verify GREEN**

Run:

```bash
/bin/bash tests/test-installer.sh
/bin/bash tests/test-wrappers.sh
```

Expected: both suites pass with zero failures.

- [x] **Step 9: Write failing two-phase publication tests**

Extend `tests/test-installer.sh` around the existing mocked full-flow test.
Require the success case to produce exactly:

```text
<project>/.wari/php
<project>/.wari/composer
<project>/.wari/serve
<project>/.wari/frankenphp
<project>/.wari/manifest.json
<project>/.wari/runtime/frankenphp
<project>/.wari/runtime/composer.phar
<project>/wari
```

Assert there is no `<project>/.wari/wari` and no
`<project>/.wari-install.*`. Add controlled failure cases for:

1. the staging-to-`.wari` rename;
2. failure to hard-link `.wari/wari` to the root dispatcher because a
   destination appeared concurrently;
3. replacement of the published root dispatcher before cleanup;
4. a public dispatcher smoke check after both paths are published.

For runtime-rename and public-smoke failures, assert no `.wari`, no `wari`, and
no staging residue. For the concurrent dispatcher collision, assert `.wari`
and staging are removed while the independently created `wari` remains
unchanged. Use shell-function `mv` and `ln` doubles only at the filesystem
boundary and assert real observable filesystem state, not mock call counts.

- [x] **Step 10: Run the installer suite and verify RED**

Run `/bin/bash tests/test-installer.sh`.

Expected: layout and failure-cleanup assertions fail because current `main`
renames staging directly to `wari/` and has no published-path ownership state.

- [x] **Step 11: Implement transaction-like publication and cleanup**

Initialize `PUBLISHED_RUNTIME=0` and `PUBLISHED_DISPATCHER=0` in global and
reset state. Add `publish_install(staging, project_root)` with this exact order:

1. Recheck that `$project_root/.wari` and `$project_root/wari` are absent using
   `-e` and `-L`.
2. Rename staging to `$project_root/.wari`.
3. Clear `STAGING_DIR` immediately and set `PUBLISHED_RUNTIME=1`.
4. Require `$project_root/.wari/wari` to be an executable regular file.
5. Run `ln "$project_root/.wari/wari" "$project_root/wari"`. This must fail
   without overwriting if the destination appeared after the recheck.
6. Set `PUBLISHED_DISPATCHER=1` and retain the internal `.wari/wari` hard-link
   name until public smoke checks finish.

Extend cleanup so it may remove the exact final dispatcher only when
`PUBLISHED_DISPATCHER=1`, and the exact hidden runtime only when
`PUBLISHED_RUNTIME=1`. Remove the dispatcher before the runtime. Preserve the
existing strict staging-path guard. While `.wari/wari` exists, cleanup may
remove root `wari` only when
`[[ "$project_root/wari" -ef "$project_root/.wari/wari" ]]` proves both names
refer to the installer-generated file; preserve a root dispatcher that was
replaced with a different file. Clear both ownership flags only after all
public smoke checks succeed; normal errors and handled signals retain the trap
long enough to clean both published paths. Add `ln` to `require_commands`.

Do not claim crash-level atomicity: `SIGKILL` or power loss can leave a complete
`.wari/` between runtime publication and dispatcher hard-link creation.
Preflight must stop on that partial state for manual review.

- [x] **Step 12: Write failing public smoke-check tests**

Add installer tests that call the wished-for
`run_public_smoke_checks(project_root)` interface. Use a generated dispatcher
and fake internal wrappers to record the delegated commands. Require these
exact public calls:

```bash
"$project_root/wari" php --version
"$project_root/wari" composer --version
"$project_root/wari" frankenphp version
"$project_root/wari" php -r \
  '$data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR); exit(is_array($data) ? 0 : 1);' \
  "$project_root/.wari/manifest.json"
```

Assert `main` reaches these calls only after both final paths exist. Force one
delegated command to fail and assert the publication cleanup removes both final
paths.

- [x] **Step 13: Run the public smoke-check test and verify RED**

Run `/bin/bash tests/test-installer.sh`.

Expected: failure because `run_public_smoke_checks` does not exist and `main`
does not invoke the installed root dispatcher.

- [x] **Step 14: Implement public smoke checks**

Implement `run_public_smoke_checks(project_root)` with the four exact commands
from Step 12. Keep the existing internal staged checks before publication. Call
the new function after `publish_install`; after it succeeds, unlink
`.wari/wari`, clear publication ownership flags, and then clear the traps.

- [x] **Step 15: Run both offline suites and verify GREEN**

Run:

```bash
/bin/bash tests/test-installer.sh
/bin/bash tests/test-wrappers.sh
```

Expected: both suites pass with zero failures.

- [x] **Step 16: Update success output and all documentation**

Update `README.md`, success text, security examples, troubleshooting, and manual
verification commands to use:

```bash
./wari php --version
./wari composer require vendor/package
./wari serve
./wari frankenphp version
```

Document `.wari/manifest.json`, `.wari/runtime/frankenphp`, the intentional
breaking change, dual-path refusal, and the hard-crash partial-state limitation.
Keep the raw repository URL at
`https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh` and
change the optional attestation command to:

```bash
gh attestation verify ./.wari/runtime/frankenphp --owner php
```

- [x] **Step 17: Update the live test and CI-consumed behavior**

Change `tests/test-live-install.sh` to assert executable `<project>/wari`, hidden
runtime files under `<project>/.wari/`, and absence of `.wari/wari`. Run PHP,
Composer, FrankenPHP, Composer plain-`php` scripts, Composer `@php` scripts, and
the server exclusively through `./wari <command>`. The workflow file needs no
command change because it invokes the test scripts rather than installed Wari
commands.

- [x] **Step 18: Run complete verification**

Run:

```bash
/bin/bash -n install.sh tests/*.sh
/bin/bash tests/test-installer.sh
/bin/bash tests/test-wrappers.sh
/bin/bash tests/test-live-install.sh
WARI_RUN_LIVE=1 /bin/bash tests/test-live-install.sh
git diff --check
git status --short --branch
```

Expected: syntax succeeds; both offline suites report zero failures; the default
live test explicitly skips; the opt-in live test verifies install, Composer
child scripts, and loopback HTTP; `git diff --check` is clean. Report the actual
staged/unstaged state without modifying it.

- [x] **Step 19: User review checkpoint**

Show the final layout, public command examples, test counts, live versions, and
all modified files. Do not run `git add`, `git commit`, `git push`, worktree
creation, branch creation, merge, or cleanup of user-managed Git state.
