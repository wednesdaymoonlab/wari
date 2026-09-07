# Wari Project-Local Team Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generated platform-bound root dispatcher with a committed portable launcher and lock file, while keeping each machine's explicitly installed runtime ignored and reproducible.

**Architecture:** Add a source-controlled `wari` launcher that strictly parses `wari.lock`, validates local `.wari/` state, and owns setup/update/dispatch. Reduce `install.sh` to a project initializer and legacy-layout migrator; retain generated runtime wrappers inside `.wari/` and adapt `create-project` to preserve tracked Wari files and merge ignore rules.

**Tech Stack:** Bash 3.2-compatible shell, curl, POSIX/macOS checksum utilities, GitHub Releases API, FrankenPHP standalone PHP CLI, Composer installer/PHAR, existing shell test harness

**Spec:** `docs/superpowers/specs/2026-09-07-wari-project-local-team-runtime-design.md`

## Global Constraints

- Never run `git add`, `git commit`, or `git push`; `AGENTS.md` requires all changes to remain unstaged for user review.
- Support Linux x86_64/ARM64 and macOS Intel/Apple Silicon with Bash 3.2 compatibility.
- `wari`, `wari.lock`, and the Wari `.gitignore` block are tracked; `.wari/` and every Wari staging, backup, update, and setup-lock path are ignored.
- Runtime downloads or replacement happen only through explicit `./wari setup`; runtime-dependent commands never download or mutate local state.
- `setup` never runs the application's `composer install`.
- Lock parsing treats every byte as data and never uses `source`, `eval`, or arbitrary lock-provided URLs.
- Exact Wari, FrankenPHP, Composer installer, and Composer PHAR checksums come from the reviewed lock/release metadata.
- Existing user paths are never moved or deleted unless Wari proves ownership and validates an exact direct-child path.
- A failed setup preserves a previously valid runtime; a failed update preserves or detects the tracked launcher/lock pair.
- Windows, implicit setup, global installation, arbitrary update version combinations, and automatic Git mutation remain out of scope.

---

## File Structure

- Create `wari`: committed, sourceable Bash launcher containing lock parsing, platform selection, runtime validation, setup/update orchestration, wrapper generation, manifest handling, and command dispatch.
- Create `wari.lock`: generated release-default lock checked into the Wari source repository and copied into application repositories.
- Create `tools/generate-lock.sh`: maintainer tool that emits a complete canonical lock from exact versions and verified official artifacts.
- Rewrite `install.sh`: thin initializer plus explicit `--migrate` support; it publishes tracked files and manages the ignore block but never creates a runtime.
- Create `tests/test-lock.sh`: strict parser, canonical lock, checksum selection, and malicious-input tests.
- Create `tests/test-launcher.sh`: pre-setup commands, runtime validation, dispatch, and no-implicit-network tests.
- Create `tests/test-setup.sh`: exact artifact install, setup locking, idempotency, replacement, rollback, and cleanup tests.
- Create `tests/test-update.sh`: release selection and transaction-like tracked-file update tests.
- Modify `tests/test-installer.sh`: initializer, ignore-block, collision, pipe mode, and migration tests.
- Modify `tests/test-wrappers.sh`: source wrapper generators from `wari` and retain wrapper regression coverage.
- Modify `tests/test-create-project.sh`: require `wari.lock` and bootstrap `.gitignore`, then test `.gitignore` merging and rollback.
- Modify `tests/test-live-install.sh`: execute initialize → setup → dispatch → repeat setup → create-project.
- Create `tests/fixtures/wari-release.json`: deterministic GitHub release metadata for `wari` and `wari.lock` assets.
- Modify `.github/workflows/test.yml`: run every offline suite on the platform matrix and the revised live flow on demand.
- Modify `.gitignore`, `README.md`, and compatibility guides to document and exercise the tracked/local boundary.

---

### Task 1: Canonical Lock Format and Maintainer Generator

**Files:**

- Create: `wari`
- Create: `wari.lock`
- Create: `tools/generate-lock.sh`
- Create: `tests/test-lock.sh`
- Modify: `.gitignore`

**Interfaces:**

- Produces: `parse_lock <path>`, `lock_digest <path>`, `select_locked_asset`, `calculate_checksum <sha256|sha384> <file>`.
- Produces globals: `LOCK_VERSION`, `LOCK_WARI_VERSION`, `LOCK_FRANKENPHP_VERSION`, `LOCK_COMPOSER_VERSION`, `LOCK_LINUX_BUILD`, `LOCK_WARI_SHA256`, `LOCK_COMPOSER_INSTALLER_SHA384`, `LOCK_COMPOSER_SHA256`, and four platform checksum variables.
- Consumes: fixed lock schema from the approved spec; no earlier task interface.

- [x] **Step 1: Write strict parser tests**

Create `tests/test-lock.sh` using `test-helper.sh`, source `wari`, and build locks with literal safe values:

```bash
write_valid_lock() {
    local path="$1"
    {
        printf '%s\n' 'lock_version=1' 'wari_version=0.2.0' \
            'frankenphp_version=1.12.7' 'composer_version=2.8.11' \
            'linux_build=static'
        printf 'wari_sha256=%064d\n' 0
        printf 'composer_installer_sha384=%096d\n' 0
        printf 'composer_sha256=%064d\n' 1
        printf 'frankenphp_linux_x86_64_sha256=%064d\n' 2
        printf 'frankenphp_linux_arm64_sha256=%064d\n' 3
        printf 'frankenphp_macos_x86_64_sha256=%064d\n' 4
        printf 'frankenphp_macos_arm64_sha256=%064d\n' 5
    } >"$path"
}
```

Assert acceptance of the valid file and rejection of missing keys, duplicate
keys, unknown keys, CRLF/control bytes, whitespace around `=`, uppercase or
wrong-length digests, invalid semver, unsupported `lock_version`, invalid
`linux_build`, and values containing `$(touch ...)`, backticks, semicolons, or
newlines. Confirm no sentinel file is created by malicious cases.

- [x] **Step 2: Run the parser test and verify it fails**

Run: `bash tests/test-lock.sh`

Expected: FAIL because `wari` and `parse_lock` do not exist.

- [x] **Step 3: Implement the sourceable launcher foundation and parser**

Start `wari` with `set -Eeuo pipefail`, an embedded `WARI_VERSION='0.2.0'`,
state reset, and a parser that reads without evaluation:

```bash
parse_lock() {
    local path="$1" line key value
    [[ -f "$path" && ! -L "$path" ]] || { die "invalid Wari lock: $path"; return 1; }
    reset_lock_state
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[a-z0-9_]+=[^[:space:][:cntrl:]]+$ ]] || {
            die "invalid Wari lock line: $line"; return 1;
        }
        key="${line%%=*}"
        value="${line#*=}"
        assign_lock_value "$key" "$value" || return 1
    done <"$path"
    validate_complete_lock
}
```

Implement `assign_lock_value` as an explicit `case` over all schema keys with a
separate seen flag per key. Validate versions with
`^[0-9]+\.[0-9]+\.[0-9]+$`, SHA-256 with `^[0-9a-f]{64}$`, SHA-384 with
`^[0-9a-f]{96}$`, and Linux build with `static|gnu`. Do not use dynamic variable
assignment from an input key.

- [x] **Step 4: Add checksum selection and canonical-output tests**

Test `select_locked_asset` after setting normalized `PLATFORM_OS` and
`PLATFORM_ARCH`; require exact asset/checksum mappings for all four supported
platforms and both Linux build names. Test that `tools/generate-lock.sh --help`
documents these required inputs:

```text
tools/generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>
```

- [x] **Step 5: Implement the maintainer generator**

Make the tool validate its four arguments, fetch the exact FrankenPHP release
metadata, select all required asset digests, download and verify the official
Composer installer, install/download the exact Composer PHAR using
`--version=<exact>`, and emit keys in the canonical order from the spec. Compute
`wari_sha256` from the repository's `wari`; compute the installer SHA-384 and
PHAR SHA-256 locally. Use a `mktemp -d` workspace with an exact-prefix cleanup
trap and print only the lock to stdout.

- [x] **Step 6: Generate and validate the repository lock**

Run:

```bash
tools/generate-lock.sh 0.2.0 1.12.7 2.8.11 static >wari.lock
bash tests/test-lock.sh
bash -n wari tools/generate-lock.sh
```

Expected: the generated `wari.lock` parses successfully, all lock tests pass,
and both scripts pass syntax validation. This networked generation step may use
a newer exact stable FrankenPHP or Composer release if `1.12.7` or `2.8.11` is
unavailable; record the chosen exact versions in the generated lock and README.

- [x] **Step 7: Extend repository ignore rules and review**

Append the exact five Wari local-state patterns from the spec to `.gitignore`.
Run `git diff --check` and `git status --short`; leave changes unstaged.

---

### Task 2: Tracked Launcher Dispatch and Runtime Validation

**Files:**

- Modify: `wari`
- Create: `tests/test-launcher.sh`
- Modify: `tests/test-wrappers.sh`

**Interfaces:**

- Consumes: Task 1 lock globals and `lock_digest`.
- Produces: `validate_runtime <project-root>`, `dispatch_runtime <command> [args...]`, `launcher_main [args...]`.
- Produces validation results: `missing`, `unrecognized`, `incomplete`, `stale-lock`, `platform-mismatch`, or `ready` through focused diagnostics and shell status.

- [x] **Step 1: Write pre-setup launcher tests**

Build a fixture containing copied `wari` and `wari.lock` but no `.wari/`.
Assert `help`, `--help`, and `--version` return zero without invoking a stubbed
`curl`. Assert `php`, `composer`, `serve`, `frankenphp`, and `create-project`
all return non-zero, contain `./wari setup`, create no `.wari/`, and never call
the network stub. Assert an unknown command prints usage without runtime access.

- [x] **Step 2: Run the launcher test and verify it fails**

Run: `bash tests/test-launcher.sh`

Expected: FAIL because the new launcher has no command router or validation.

- [x] **Step 3: Move runtime wrapper generation into the tracked launcher**

Move the current `generate_wrappers()` heredocs and focused create-project
helper bodies from `install.sh:613-1110` into sourceable functions in `wari`.
Do not generate `.wari/wari`; the root tracked launcher is now the only public
dispatcher. Update `tests/test-wrappers.sh` to source `wari` and keep all PHP,
Composer, serve, FrankenPHP, argument-preservation, working-directory, exit
status, and PHP compatibility assertions unchanged.

- [x] **Step 4: Implement manifest parsing and runtime validation**

Use constrained field extraction for the Wari-authored manifest; never source
JSON. Require a real `.wari/`, exact layout/manifest version, matching
`lock_sha256`, OS, architecture, Linux build, Wari/FrankenPHP/Composer versions,
regular executable wrappers, executable FrankenPHP, and regular Composer PHAR.
Run lightweight version commands only after structural checks pass.

Implement the dispatch boundary exactly:

```bash
dispatch_runtime() {
    local command_name="$1"
    shift
    validate_runtime "$WARI_PROJECT_ROOT" || {
        printf '\nRun:\n  ./wari setup\n' >&2
        return 1
    }
    cd -- "$WARI_PROJECT_ROOT"
    exec "$WARI_RUNTIME_DIR/$command_name" "$@"
}
```

- [x] **Step 5: Add ready/stale/platform/corrupt validation tests**

Create owned fixtures for every validation state, including a symlinked runtime,
missing manifest, missing wrapper, changed lock, copied macOS manifest on Linux,
wrong reported version, and unrecognized `.wari/`. Assert diagnostic category,
non-zero status, no mutation, and no network. Add a ready fixture that verifies
argument and exit-status forwarding.

- [x] **Step 6: Run focused and wrapper suites**

Run:

```bash
bash tests/test-lock.sh
bash tests/test-launcher.sh
bash tests/test-wrappers.sh
bash -n wari
```

Expected: all pass. Review with `git diff --check`; leave changes unstaged.

---

### Task 3: Exact Artifact Installation and Staged Manifest

**Files:**

- Modify: `wari`
- Create: `tests/test-setup.sh`
- Modify: `tests/fixtures/frankenphp-release.json`

**Interfaces:**

- Consumes: lock parser/checksum selection from Task 1 and wrapper generation from Task 2.
- Produces: `create_runtime_staging`, `install_locked_frankenphp <staging>`, `install_locked_composer <staging>`, `write_manifest <staging>`, `run_staged_smoke_checks <staging>`.

- [x] **Step 1: Write failing exact-artifact tests**

Stub downloads by canonical URL and capture Composer installer arguments. Assert
FrankenPHP uses the platform-selected exact version URL and locked SHA-256.
Assert Composer installer checksum is checked against
`LOCK_COMPOSER_INSTALLER_SHA384`, invocation contains all of:

```text
--quiet
--version=2.8.11
--install-dir=<staging>/runtime
--filename=composer.phar
```

Assert Wari then checks PHAR SHA-256 and reported Composer version. Include a
separate failing case for each download, checksum, installer exit, missing PHAR,
and version mismatch.

- [x] **Step 2: Run the setup suite and verify it fails**

Run: `bash tests/test-setup.sh`

Expected: FAIL because locked artifact installers are absent.

- [x] **Step 3: Adapt existing download/checksum code in `wari`**

Move the retry/progress/checksum helpers from `install.sh:159-414`, retaining
bounded retries and TTY-only progress. Remove latest-release resolution from the
setup path. Derive canonical URLs only from validated versions and selected
asset names; reject redirects/final URLs outside the existing official host
allowlist where curl exposes them.

- [x] **Step 4: Implement exact FrankenPHP and Composer installation**

Use the selected lock checksum before renaming a `.download` file into place.
For Composer, verify the installer before execution, pass the exact version,
then verify PHAR digest and reported version before removing setup files.

- [x] **Step 5: Write the expanded manifest and staged smoke tests**

Write deterministic JSON fields for layout version, lock digest, normalized
platform, selected build, exact versions, URLs/checksums, installed PHP version,
installation time, `checksum_verified: true`, and `slsa_verified: false`.
Smoke-check every wrapper, Composer/PHP/FrankenPHP version, create-project help,
and JSON decoding before publication.

- [x] **Step 6: Run artifact and regression tests**

Run:

```bash
bash tests/test-setup.sh
bash tests/test-wrappers.sh
bash -n wari
```

Expected: all pass with no real network calls in offline suites.

---

### Task 4: Idempotent Setup, Locking, Publication, and Rollback

**Files:**

- Modify: `wari`
- Modify: `tests/test-setup.sh`
- Modify: `tests/test-launcher.sh`

**Interfaces:**

- Consumes: `validate_runtime`, Task 3 staged runtime functions.
- Produces: `setup_main [--yes]`, `acquire_setup_lock`, `publish_runtime <staging>`, `cleanup_setup`, `restore_runtime_backup`.

- [x] **Step 1: Add lifecycle failure tests**

Cover initial install, valid no-op with no network, recognized stale lock,
recognized cross-platform runtime, owned incomplete runtime, unrecognized
runtime refusal, active setup lock, noninteractive download without `--yes`,
declined confirmation, paths with spaces, and GNU/glibc rejection.

Inject failures before backup, after backup, after publication, and during
public smoke checks. Assert an old valid runtime is restored byte-for-byte and
no normal staging/backup path remains. Send `TERM` and `INT` to blocking fake
downloads and assert conventional 143/130 statuses with safe cleanup.

- [x] **Step 2: Run lifecycle tests and verify they fail**

Run: `bash tests/test-setup.sh`

Expected: new lifecycle cases FAIL because `setup_main` is absent.

- [x] **Step 3: Implement atomic setup locking and safe path predicates**

Use `mkdir "$PROJECT_ROOT/.wari-setup.lock"` as the atomic acquisition. Store
PID and start time for diagnostics, but never assume a recorded PID proves
ownership on another host. Define separate exact validators for install,
backup, and lock paths; every destructive cleanup calls the relevant validator
immediately before an explicit quoted removal.

- [x] **Step 4: Implement setup state machine**

Route `./wari setup [--yes]` to: parse lock → detect platform → acquire lock →
no-op if ready → confirm if mutation → stage/install/smoke → move recognized old
runtime to backup → publish staging → public smoke → delete backup. Install
traps before the first temporary path and clear them only after state flags show
successful completion.

- [x] **Step 5: Implement rollback by ownership flags**

Track `STAGING_CREATED`, `OLD_RUNTIME_BACKED_UP`, and
`NEW_RUNTIME_PUBLISHED`. Cleanup removes only validated paths created by the
invocation. If public smoke fails, move the failed new owned runtime back to its
staging/failed path, restore the exact backup, and preserve the original error
status. Refuse cleanup rather than broadening a target when validation fails.

- [x] **Step 6: Run setup and launcher regression suites**

Run:

```bash
bash tests/test-setup.sh
bash tests/test-launcher.sh
bash tests/test-lock.sh
bash tests/test-wrappers.sh
```

Expected: all pass, including no-op/no-network and rollback cases.

---

### Task 5: Project Initializer and Managed Ignore Block

**Files:**

- Rewrite: `install.sh`
- Modify: `tests/test-installer.sh`
- Create: `tests/fixtures/wari-release.json`

**Interfaces:**

- Consumes: GitHub release assets named exactly `wari` and `wari.lock`.
- Produces: `initializer_main [--yes]`, `parse_wari_release <json>`, `install_tracked_files <project-root>`, `ensure_gitignore_block <project-root>`.

- [x] **Step 1: Replace installer expectations with initializer tests**

Test direct and pipe-mode help, exact release asset selection, foreign-host and
duplicate-asset rejection, checksum failures, collisions, broken symlinks,
paths with spaces, executable mode, and rollback. A successful fixture must
contain `wari`, `wari.lock`, and one managed ignore block, but no `.wari/` and
no FrankenPHP/Composer network calls. Repeating ignore management must preserve
unrelated content and not duplicate the block.

- [x] **Step 2: Run installer tests and verify old behavior fails**

Run: `bash tests/test-installer.sh`

Expected: FAIL because current `install.sh` publishes runtime plus a linked
dispatcher instead of tracked files.

- [x] **Step 3: Rewrite `install.sh` as a sourceable thin initializer**

Retain safe curl retry, checksum, terminal, JSON release parsing, staging, and
entrypoint-guard patterns. Remove runtime/platform selection, wrapper generation,
Composer/FrankenPHP installation, and `.wari/` publication. Fetch exactly the
two Wari release assets, validate GitHub `sha256:` digests, validate the
candidate lock and candidate launcher's embedded version by invoking the
candidate only in non-mutating validation mode, then publish both files with
ordered renames and rollback flags.

- [x] **Step 4: Implement exact ignore-block editing**

Read an existing regular non-symlink `.gitignore`, preserve its bytes, add one
separating newline only when required, and append the exact managed block.
Stage the replacement in the project root and rename it; do not edit through a
symlink. Treat a newly created `.gitignore` as a tracked initializer output.

- [x] **Step 5: Verify initializer suites**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-lock.sh
bash -n install.sh wari
```

Expected: all pass; installation output says `./wari setup` is next and lists
all tracked files changed.

---

### Task 6: Reviewable `update` Command

**Files:**

- Modify: `wari`
- Create: `tests/test-update.sh`
- Reuse: `tests/fixtures/wari-release.json`

**Interfaces:**

- Consumes: release selection rules from Task 5 and current lock validation.
- Produces: `update_main [--yes]`, `stage_update_pair`, `publish_update_pair`, `rollback_update_pair`.

- [x] **Step 1: Write updater tests**

Test help/arguments, version comparison output, confirmation and decline,
`--yes`, exact two-asset selection, candidate checksums, launcher/lock version
agreement, preserved executable mode, no `.wari/` mutation, and next-step
instructions. Assert refusal when current `wari` hash differs from
`LOCK_WARI_SHA256`.

Inject interruption/failure before either rename, between launcher and lock
renames, and after both. Assert either the old pair is restored or the next
launcher call reports a detected pair mismatch with Git recovery instructions.

- [x] **Step 2: Run updater tests and verify they fail**

Run: `bash tests/test-update.sh`

Expected: FAIL because `update_main` is absent.

- [x] **Step 3: Implement staged update and validation**

Share launcher-local GitHub release parsing/download helpers without sourcing
the remote installer. Stage under `.wari-update.<random>`, verify API digests,
strictly parse the candidate lock, check candidate embedded Wari version, and
check candidate `wari_sha256` against the candidate launcher before prompting.

- [x] **Step 4: Implement transaction-like publication and recovery**

Back up only the exact regular current `wari` and `wari.lock`; replace with
ordered renames and restore on trapped failures. Because two files cannot be
one atomic rename, make normal launcher startup verify its own SHA-256 and
embedded version against the lock before any mutating or runtime command. A
mismatch prints rerun-update/Git-restore guidance and returns non-zero.

- [x] **Step 5: Run update and launcher tests**

Run:

```bash
bash tests/test-update.sh
bash tests/test-launcher.sh
bash tests/test-lock.sh
```

Expected: all pass and `.wari/` fixture mtimes/content remain unchanged during
update.

---

### Task 7: Explicit Legacy Layout Migration

**Files:**

- Modify: `install.sh`
- Modify: `tests/test-installer.sh`

**Interfaces:**

- Consumes: legacy `.wari/manifest.json`, `.wari/wari`, and root dispatcher inode relationship.
- Produces: `migrate_legacy_layout <project-root>` exposed only by `install.sh --migrate`.

- [x] **Step 1: Write recognized and ambiguous migration tests**

Construct the current layout with `ln .wari/wari wari`. Assert normal
initialization refuses it and `--migrate` accepts only when manifest/layout are
valid and `wari -ef .wari/wari`. Reject copied-but-not-linked dispatchers,
symlinks, missing manifest, foreign `.wari/`, existing `wari.lock`, and a
locally replaced root dispatcher.

On success assert the new root `wari` is a regular tracked launcher not equal
to `.wari/wari`, the legacy runtime remains untouched, the lock and ignore block
exist, and runtime dispatch tells the user to run setup. Inject publication
failures and assert restoration of the legacy root link.

- [x] **Step 2: Run migration tests and verify they fail**

Run: `bash tests/test-installer.sh`

Expected: migration cases FAIL because `--migrate` is not implemented.

- [x] **Step 3: Implement ownership proof and migration publication**

Parse only the minimal known legacy manifest fields, require the exact legacy
wrapper layout, verify root and internal dispatchers with `-ef`, then stage the
new pair. Replace only root `wari`; never delete or modify `.wari/`. Use a
validated backup hard link/file and state flags so failure restores the legacy
dispatcher. Publish the lock and ignore block only within the same rollback
scope.

- [x] **Step 4: Run initializer and launcher suites**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-launcher.sh
```

Expected: all initializer, collision, migration, and post-migration guidance
tests pass.

---

### Task 8: `create-project` Tracked Files and `.gitignore` Merge

**Files:**

- Modify: `wari`
- Modify: `tests/test-create-project.sh`

**Interfaces:**

- Consumes: tracked root `wari`, `wari.lock`, bootstrap-only `.gitignore`, and local `.wari/`.
- Produces: strict four-entry preflight and `merge_staged_gitignore <staging> <project-root>`.

- [x] **Step 1: Update fixtures and write failing four-entry tests**

Change the base fixture to contain exactly `.wari/`, `wari`, `wari.lock`, and
the canonical bootstrap `.gitignore`. Require regular non-symlink tracked files
and exact bootstrap ignore content. Assert rejection of missing/modified files
and every fifth root entry.

Add successful cases where the Composer project has no `.gitignore`, has a
newline-terminated `.gitignore`, and has one without a final newline. Assert
package rules are byte-preserved and the Wari block occurs exactly once. Add a
staged `wari.lock` collision rejection.

- [x] **Step 2: Run create-project tests and verify they fail**

Run: `bash tests/test-create-project.sh`

Expected: FAIL because current preflight expects two entries and rejects/does
not merge staged `.gitignore`.

- [x] **Step 3: Implement four-entry validation and staged merge**

Update reserved paths to `wari|wari.lock|.wari`. Validate the root
`.gitignore` against the exact initializer block before Composer runs. If the
staged project has a regular `.gitignore`, create a sibling temporary merged
file preserving its content, add a separating newline only when necessary, and
append the Wari block only if absent. Reject staged `.gitignore` symlinks and
malformed partial Wari blocks.

- [x] **Step 4: Integrate `.gitignore` into owned publication rollback**

Record the bootstrap `.gitignore` backup before replacing it. On any later
publication error or signal, remove only the invocation-owned final file and
restore the exact bootstrap file. Preserve concurrently replaced files and
report rollback conflicts rather than overwriting them.

- [x] **Step 5: Run create-project and wrapper suites**

Run:

```bash
bash tests/test-create-project.sh
bash tests/test-wrappers.sh
bash tests/test-launcher.sh
```

Expected: all pass, including existing argument forwarding, Composer exit
status, concurrency, signal cleanup, and paths-with-spaces cases.

---

### Task 9: Documentation, CI Matrix, and Live End-to-End Verification

**Files:**

- Modify: `README.md`
- Modify: `docs/compatibility/README.md`
- Modify: `docs/compatibility/cakephp.md`
- Modify: `docs/compatibility/codeigniter.md`
- Modify: `docs/compatibility/laravel.md`
- Modify: `docs/compatibility/slim.md`
- Modify: `docs/compatibility/symfony.md`
- Modify: `docs/compatibility/wordpress.md`
- Modify: `tests/test-live-install.sh`
- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: final initializer, launcher, lock, setup, update, migration, and create-project commands.
- Produces: documented clone/update/CI workflows and cross-platform verification commands.

- [x] **Step 1: Rewrite README lifecycle documentation**

Lead with initialize then explicit setup. Document tracked versus ignored files,
clone onboarding, no implicit downloads, exact lock contents, branch-switch
mismatch, `update` review flow, CI setup, executable-bit recovery with
`bash ./wari setup`, static/GNU choice, legacy `--migrate`, four-entry
create-project bootstrap, security limits, and troubleshooting. Remove every
statement that `install.sh` directly publishes `.wari/`.

- [x] **Step 2: Update compatibility guides**

Insert `./wari setup` before the first Composer/PHP use in every guide. Keep
framework-specific commands in compatibility files only and retain the main
README's framework-neutral examples.

- [x] **Step 3: Rewrite live test around the explicit lifecycle**

Copy repository `install.sh` into an empty fixture while stubbing its release
base to local `wari`/`wari.lock` assets, initialize, assert no `.wari/`, then run
real `./wari setup --yes`. Verify exact locked platform/checksums/versions,
PHP/Composer commands, Composer child PHP behavior, loopback HTTP serving, and
a second setup with a network-failing curl stub to prove the no-op path.

Create a separate four-entry fixture and run real
`./wari create-project --yes composer/hello-world --no-interaction`; verify the
final ignore merge and tracked/runtime preservation.

- [x] **Step 4: Expand the offline CI job**

Run in this order on all existing Linux/macOS x86_64/ARM64 runners:

```bash
bash tests/test-lock.sh
bash tests/test-launcher.sh
bash tests/test-setup.sh
bash tests/test-update.sh
bash tests/test-installer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
```

Keep the opt-in live matrix for Linux static/GNU and both macOS architectures;
change its step to the revised live script. Do not run `wari update` in CI.

- [x] **Step 5: Run all offline verification**

Run:

```bash
bash -n install.sh wari tools/generate-lock.sh tests/test-*.sh
bash tests/test-lock.sh
bash tests/test-launcher.sh
bash tests/test-setup.sh
bash tests/test-update.sh
bash tests/test-installer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
git diff --check
```

Expected: every command exits zero and offline tests make no real external
network request.

- [x] **Step 6: Run approved live verification**

Run: `WARI_RUN_LIVE=1 bash tests/test-live-install.sh`

Expected: exact locked artifacts install, the second setup is a no-op, all
runtime commands and HTTP smoke checks pass, create-project succeeds, and no
normal Wari staging/backup path remains. This command requires network access;
request sandbox escalation if the environment blocks the approved live test.

- [x] **Step 7: Perform final review without Git mutation**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: only intended unstaged source, test, workflow, lock, and documentation
changes. Do not run `git add`, `git commit`, or `git push`.
