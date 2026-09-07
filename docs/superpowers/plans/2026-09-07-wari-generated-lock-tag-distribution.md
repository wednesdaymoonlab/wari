# Wari Generated Lock and Git Tag Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GitHub Release asset distribution with exact Git-tag launcher downloads, generate `wari.lock` during initialization, separate dependency updates from launcher self-updates, and preserve explicit local runtime setup.

**Architecture:** Keep the existing portable Bash launcher as the single owner of strict lock parsing, upstream metadata resolution, and canonical lock generation. The thin initializer stages either an exact-tag launcher or a local launcher and asks that staged launcher to generate its lock; `update` and `self-update` reuse the same generator so every workflow produces the same format. Runtime setup and wrappers remain unchanged except that any changed lock continues to invalidate the local manifest until explicit setup.

**Tech Stack:** Bash 3.2-compatible shell, curl, awk/sed, SHA-256/SHA-384 command-line utilities, GitHub Releases metadata for FrankenPHP, official Composer metadata/checksum endpoints, shell test harness, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-07-wari-generated-lock-tag-distribution-design.md`

## Global Constraints

- Work directly in the existing `main` checkout; do not create a branch or worktree.
- Never run `git add`, `git commit`, or `git push`; leave every change unstaged for user review.
- Use `WARI_VERSION='0.2.1'`; the user authorized the patch bump because the
  immutable `v0.2.0` tag already exists on the remote.
- Accept only exact semantic versions matching `MAJOR.MINOR.PATCH`; do not accept ranges or prereleases.
- Support Linux x86-64, Linux ARM64, macOS Intel, and macOS Apple Silicon; Windows remains unsupported.
- Initialization defaults to `linux_build=static`; dependency update preserves the locked build unless `--linux-build` is passed.
- Download only from fixed official Wari, FrankenPHP, GitHub API, and Composer HTTPS hosts.
- Never source a lock file or remote metadata.
- Never download or repair `.wari/` except through explicit `./wari setup`.
- Preserve Bash 3.2 compatibility: no associative arrays, namerefs, `mapfile`, or Bash 4-only parameter features.
- Every implementation task follows red-green-refactor: add a focused failing test, observe the expected failure, implement the smallest complete behavior, then rerun focused and related regression tests.
- Because repository rules prohibit commits, each task ends with a read-only `git diff --check` and `git status --short` checkpoint instead of a commit.

## File Structure

- Modify `wari`: own semantic-version validation, official metadata parsers, canonical lock generation, dependency-only `update`, exact-tag `self-update`, and hidden bootstrap interfaces.
- Modify `install.sh`: own initializer option parsing, exact-tag/local-source launcher staging, transactional publication, and invocation of the staged launcher's lock generator.
- Modify `tools/generate-lock.sh`: retain a maintainer-friendly exact-version wrapper, delegating generation to `wari` instead of duplicating download and parsing logic.
- Modify `wari.lock`: regenerate the repository's launcher digest and upstream checksum data after the launcher changes.
- Modify `tests/test-lock.sh`: test metadata parsing, exact/latest resolution, canonical generation, retry behavior, and unsafe output rejection.
- Modify `tests/test-initializer.sh`: test tag URLs, local source, overrides, defaults, publication, migration, and rollback.
- Modify `tests/test-update.sh`: replace release-pair tests with dependency-only update and exact-version self-update tests.
- Modify `tests/test-launcher.sh`: test help/dispatch exposure and preserve the no-runtime explicit-setup contract.
- Modify `tests/test-live-install.sh`: initialize from local source, generate a real lock, then exercise real setup and runtime behavior.
- Create `tests/fixtures/composer-versions.json`: deterministic Composer stable-version metadata used by offline tests.
- Modify `tests/fixtures/frankenphp-release.json`: include stable release header fields and the complete static/GNU asset matrix needed by latest and exact tests.
- Delete `tests/fixtures/wari-release.json`: GitHub Release metadata for Wari is no longer part of the product.
- Modify `.github/workflows/test.yml`: keep offline platform coverage and make live initialization use the local source path without a Wari Release.
- Modify `README.md`: document generated locks, tag-only publication, `update`, `self-update`, and local development.
- Modify the prior design document only to add a clear supersession pointer; keep its historical content intact.

---

### Task 1: Canonical Lock Generation in the Launcher

**Files:**
- Modify: `wari` around `download_file()`, lock parsing helpers, and `launcher_main()`
- Modify: `tests/test-lock.sh`
- Create: `tests/fixtures/composer-versions.json`
- Modify: `tests/fixtures/frankenphp-release.json`

**Interfaces:**
- Consumes: existing `calculate_checksum`, `download_file`, `parse_lock`, and `validate_launcher_pair` functions.
- Produces: `validate_semver VALUE`, `parse_frankenphp_release FILE EXPECTED_VERSION LINUX_BUILD`, `parse_composer_latest FILE`, `read_checksum_value FILE LENGTH LABEL`, `generate_lock_file LAUNCHER OUTPUT FRANKENPHP_REQUEST COMPOSER_REQUEST LINUX_BUILD`, and `generate_lock_main OUTPUT [options]`.
- Produces hidden CLI contracts: `./wari --version-value`, `./wari --validate-pair LOCK`, and `./wari --generate-lock OUTPUT [--frankenphp VERSION] [--composer VERSION] [--linux-build static|gnu]`.

- [ ] **Step 1: Add deterministic upstream fixtures**

Create `tests/fixtures/composer-versions.json` with more than one stable entry so tests can prove selection rather than merely accept one value:

```json
{
  "stable": [
    {"version": "2.10.3", "path": "/download/2.10.3/composer.phar"},
    {"version": "2.8.11", "path": "/download/2.8.11/composer.phar"}
  ]
}
```

Extend `tests/fixtures/frankenphp-release.json` so it contains exactly one
`tag_name`, `draft`, and `prerelease` plus all four Linux variants and both
macOS variants for `v1.12.7`. Each asset must have a unique digest and its exact
official `browser_download_url`.

- [ ] **Step 2: Write failing parser and generator tests**

Add focused assertions to `tests/test-lock.sh` for:

```bash
assert_fails 'semantic versions reject prerelease text' validate_semver '1.2.3-rc1'

parse_frankenphp_release \
    "$TEST_DIR/fixtures/frankenphp-release.json" '1.12.7' static
assert_eq '1.12.7' "$RESOLVED_FRANKENPHP_VERSION" \
    'FrankenPHP metadata resolves the requested stable version'

parse_composer_latest \
    "$TEST_DIR/fixtures/composer-versions.json"
assert_eq '2.10.3' "$RESOLVED_COMPOSER_VERSION" \
    'Composer metadata selects the first current stable version'

assert_fails 'lock generation rejects an output symlink' \
    generate_lock_main "$LOCK_TMP/output-link"
```

Build a fake `curl` executable that recognizes these exact endpoints and copies
fixtures/checksum text to curl's `-o` destination:

```text
https://api.github.com/repos/php/frankenphp/releases/latest
https://api.github.com/repos/php/frankenphp/releases/tags/v1.12.7
https://getcomposer.org/versions
https://getcomposer.org/download/2.10.3/composer.phar.sha256sum
https://getcomposer.org/download/2.8.11/composer.phar.sha256sum
https://composer.github.io/installer.sig
```

Call the hidden entrypoint in a subprocess so the checksum is calculated from
the actual copied launcher:

```bash
PATH="$FAKE_BIN:$PATH" bash "$CORE_DIR/wari" --generate-lock \
    "$LOCK_TMP/generated.lock" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static
parse_lock "$LOCK_TMP/generated.lock"
assert_eq "$(calculate_checksum sha256 "$CORE_DIR/wari")" \
    "$LOCK_WARI_SHA256" 'generated lock binds the executing launcher bytes'
```

Also assert canonical field order, one trailing newline, all four platform
checksums, exact override behavior, latest behavior, GNU asset selection,
invalid checksum text, duplicate/missing assets, wrong URLs, draft/prerelease
metadata, retry after curl exit 18, and no partial output after failure.

- [ ] **Step 3: Run the focused test and confirm the red state**

Run:

```bash
bash tests/test-lock.sh
```

Expected: non-zero with failures showing the new parser/generator functions or
hidden `--generate-lock` command do not exist. Existing strict lock tests must
still run.

- [ ] **Step 4: Implement strict metadata parsing and canonical generation**

Add a shared semantic version validator:

```bash
validate_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        die "invalid semantic version: $1"
        return 1
    }
}
```

Implement the parser functions with awk cardinality checks. They must set only
validated scalar globals, reject drafts/prereleases and duplicates, and verify
every selected FrankenPHP URL equals:

```text
https://github.com/php/frankenphp/releases/download/v<VERSION>/<ASSET_NAME>
```

Use exact asset names:

```text
static: frankenphp-linux-x86_64, frankenphp-linux-aarch64
gnu:    frankenphp-linux-x86_64-gnu, frankenphp-linux-aarch64-gnu
macOS:  frankenphp-mac-x86_64, frankenphp-mac-arm64
```

Implement Composer latest resolution so omitted versions choose the first
stable entry and its `path` must be `/download/<VERSION>/composer.phar`. Exact
semantic-version overrides do not have to appear in the current-stable list;
their fixed `/download/<VERSION>/composer.phar.sha256sum` response establishes
availability. Read checksum endpoints as a single lowercase hexadecimal token
of the exact required length: 64 for PHAR SHA-256 and 96 for installer SHA-384.

Implement `generate_lock_file` to resolve metadata into locals and write the
exact canonical order:

```bash
{
    printf 'lock_version=1\n'
    printf 'wari_version=%s\n' "$launcher_version"
    printf 'frankenphp_version=%s\n' "$resolved_frankenphp"
    printf 'composer_version=%s\n' "$resolved_composer"
    printf 'linux_build=%s\n' "$linux_build"
    printf 'wari_sha256=%s\n' "$launcher_sha"
    printf 'composer_installer_sha384=%s\n' "$installer_sha"
    printf 'composer_sha256=%s\n' "$composer_sha"
    printf 'frankenphp_linux_x86_64_sha256=%s\n' "$linux_x86_sha"
    printf 'frankenphp_linux_arm64_sha256=%s\n' "$linux_arm_sha"
    printf 'frankenphp_macos_x86_64_sha256=%s\n' "$mac_x86_sha"
    printf 'frankenphp_macos_arm64_sha256=%s\n' "$mac_arm_sha"
} >"$candidate"
```

Validate the candidate with `parse_lock` and `validate_launcher_pair`, then
rename it over the requested regular output. Resolve the output's parent with
`pwd -P`, reject symlink/non-regular destinations, and create the temporary file
as a direct child of that parent.

Add `generate_lock_main` option parsing with exact missing-value and unknown-
option errors. Extend the early hidden-command handling in `launcher_main` so
it does not require a project lock or runtime.

- [ ] **Step 5: Run focused and launcher regressions**

Run:

```bash
bash -n wari
bash tests/test-lock.sh
bash tests/test-launcher.sh
```

Expected: syntax success and all assertions report zero failures. The existing
pre-setup runtime commands must still print the explicit `./wari setup` remedy.

- [ ] **Step 6: Inspect the task diff**

Run:

```bash
git diff --check
git status --short
```

Expected: only the launcher, lock tests, and metadata fixtures for this task are
modified/untracked; nothing is staged.

---

### Task 2: Tag and Local-Source Project Initialization

**Files:**
- Modify: `install.sh` functions `download_file`, `fetch_tracked_files`, and `initializer_main`
- Modify: `tests/test-initializer.sh`
- Delete: `tests/fixtures/wari-release.json`

**Interfaces:**
- Consumes: Task 1 hidden `--version-value`, `--generate-lock`, and `--validate-pair` launcher interfaces.
- Produces: `fetch_tagged_launcher STAGING VERSION`, `copy_local_launcher STAGING SOURCE_DIR`, `generate_staged_lock STAGING FRANKENPHP_REQUEST COMPOSER_REQUEST LINUX_BUILD`, and initializer flags `--wari`, `--frankenphp`, `--composer`, `--linux-build`, and `--local-source`.

- [ ] **Step 1: Replace release-asset tests with tag/local-source tests**

Remove `parse_wari_release` expectations from `tests/test-initializer.sh` and
instrument `download_file` to record the requested launcher URL. Assert:

```bash
assert_eq \
        'https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.2.1/wari' \
  "$DOWNLOADED_URL" \
  'initializer downloads the launcher from the exact Wari tag'
```

Add a `generate_staged_lock` test double which writes a valid lock tied to the
staged launcher and records all forwarded options. Cover:

- defaults: Wari 0.2.1, latest dependency requests, `static`;
- `--wari 0.3.0` exact tag selection;
- exact FrankenPHP and Composer overrides;
- `--linux-build gnu`;
- `--local-source "$CORE_DIR"` without any Wari network request;
- mutual exclusion of `--local-source` and `--wari`;
- missing option values and invalid semantic versions/build;
- staged launcher embedded-version mismatch;
- lock-generation failure leaves no `wari`, `wari.lock`, or changed `.gitignore`;
- existing collision and strict legacy migration behaviors.

Delete `tests/fixtures/wari-release.json` because no production test should
parse Wari GitHub Release metadata after this task.

- [ ] **Step 2: Run initializer tests and confirm the red state**

Run:

```bash
bash tests/test-initializer.sh
```

Expected: non-zero because current initialization requests the GitHub Releases
API and does not understand the new flags/local-source contract.

- [ ] **Step 3: Implement exact-tag and local launcher staging**

Allow `download_file` to accept only the additional fixed host pattern:

```bash
https://raw.githubusercontent.com/wednesdaymoonlab/wari/*
```

Construct the URL internally after `validate_semver`:

```bash
url="https://raw.githubusercontent.com/wednesdaymoonlab/wari/v$version/wari"
download_file "$url" "$staging/wari" "Wari $version launcher"
chmod 755 "$staging/wari"
```

For `--local-source`, resolve the directory physically, require `wari` to be a
regular non-symlink file, copy it to staging, and set mode 755. Do not accept a
path to an individual file.

Query the staged launcher's version with:

```bash
staged_version="$(bash "$staging/wari" --version-value)" || return 1
```

For tag mode require equality with the selected exact Wari version. For local
mode use the staged embedded version after semantic validation.

- [ ] **Step 4: Generate rather than download the project lock**

Replace release-pair download logic with an argv array compatible with Bash
3.2:

```bash
generator_args=(--generate-lock "$staging/wari.lock" --linux-build "$linux_build")
[[ -z "$frankenphp_version" ]] || generator_args+=(--frankenphp "$frankenphp_version")
[[ -z "$composer_version" ]] || generator_args+=(--composer "$composer_version")
bash "$staging/wari" "${generator_args[@]}"
bash "$staging/wari" --validate-pair "$staging/wari.lock"
```

Preserve the existing confirmation, collision checks, legacy migration,
transactional publication, signal traps, ignore-block idempotence, and final
instruction to run `./wari setup`. Update help text with the full new option
surface and state that the lock is generated.

- [ ] **Step 5: Run focused and setup regressions**

Run:

```bash
bash -n install.sh
bash tests/test-initializer.sh
bash tests/test-lock.sh
bash tests/test-setup.sh
```

Expected: all assertions report zero failures. Initialization creates tracked
files and ignore rules but no `.wari/`.

- [ ] **Step 6: Inspect the task diff**

Run:

```bash
git diff --check
git status --short
```

Expected: initializer/relevant tests changed, obsolete Wari release fixture
deleted, and nothing staged.

---

### Task 3: Dependency-Only `update`

**Files:**
- Modify: `wari` functions currently named `read_wari_release_asset`, `parse_wari_release`, `fetch_wari_update`, and `update_main`
- Rewrite: dependency-update portion of `tests/test-update.sh`
- Modify: `tests/test-launcher.sh` help assertions

**Interfaces:**
- Consumes: Task 1 `generate_lock_file`/hidden generator and existing `validate_launcher_pair`.
- Produces: `update_main [--yes] [--frankenphp VERSION] [--composer VERSION] [--linux-build static|gnu]`, which may atomically replace only `wari.lock`.

- [ ] **Step 1: Write dependency-only update tests**

Remove assertions that `update` installs Wari 0.3.0. Build a project pair from
the current launcher and lock, copy the launcher bytes before the call, and
stub lock generation to emit controlled candidate dependency versions.

Add assertions equivalent to:

```bash
launcher_before="$(calculate_checksum sha256 "$PROJECT/wari")"
update_main --yes --frankenphp 1.13.0
launcher_after="$(calculate_checksum sha256 "$PROJECT/wari")"
assert_eq "$launcher_before" "$launcher_after" \
    'dependency update never changes the launcher'
assert_contains "$(<"$PROJECT/wari.lock")" 'frankenphp_version=1.13.0' \
    'dependency update publishes the selected FrankenPHP version'
```

Cover all decision rules:

- no flags requests latest for both dependencies;
- one exact flag leaves the other request empty so it resolves latest;
- no build flag forwards the existing `linux_build`;
- explicit `--linux-build gnu` overrides it;
- candidate retains current `wari_version` and `wari_sha256`;
- identical candidate is a successful no-op without rewriting inode/mtime;
- declined confirmation preserves the lock;
- generation failure preserves the lock and local `.wari/` marker;
- modified launcher is refused before network access;
- missing values/unknown options return status 2;
- output lists old/new FrankenPHP, Composer, and Linux build and reminds the
  user to run `./wari setup`.

Update launcher help to describe `update` as dependency lock update and list
`self-update` separately in preparation for Task 4.

- [ ] **Step 2: Run update tests and confirm the red state**

Run:

```bash
bash tests/test-update.sh
```

Expected: non-zero because current `update` downloads and replaces a Wari
release pair.

- [ ] **Step 3: Replace Wari release update logic**

Delete `read_wari_release_asset`, `parse_wari_release`, and `fetch_wari_update`
from `wari`. Parse all dependency flags in any order, reject duplicates, and
validate values before making a network request.

At startup:

```bash
validate_launcher_pair "$WARI_LAUNCHER" "$WARI_PROJECT_ROOT/wari.lock"
current_frankenphp="$LOCK_FRANKENPHP_VERSION"
current_composer="$LOCK_COMPOSER_VERSION"
current_linux_build="$LOCK_LINUX_BUILD"
```

Create `.wari-update.XXXXXX`, copy the current launcher into it without
modifying the public launcher, and invoke the copied launcher's generator. Pass
an omitted dependency as no flag so Task 1 resolves latest; always pass either
the current or explicitly requested Linux build.

Validate the candidate pair, verify its Wari identity equals the current pair,
display the comparison, and compare candidate/current locks with `cmp -s`. For
a change, back up the old lock inside staging, rename the candidate over
`wari.lock`, revalidate the public pair, and restore the old lock on any error
or signal. Never move, chmod, or replace `WARI_LAUNCHER`.

- [ ] **Step 4: Run focused and launcher regressions**

Run:

```bash
bash -n wari
bash tests/test-update.sh
bash tests/test-launcher.sh
bash tests/test-setup.sh
```

Expected: zero failures, unchanged launcher bytes, unchanged `.wari/`, and an
updated lock makes the existing runtime fail validation until setup.

- [ ] **Step 5: Inspect the task diff**

Run:

```bash
git diff --check
git status --short
```

Expected: launcher/update tests changed and nothing staged.

---

### Task 4: Exact-Version `self-update`

**Files:**
- Modify: `wari` near `update_main` and `launcher_main`
- Extend: `tests/test-update.sh`
- Modify: `tests/test-launcher.sh`

**Interfaces:**
- Consumes: Task 1 hidden generator and pair validation; Task 3 staging/rollback patterns.
- Produces: `fetch_tagged_wari_launcher STAGING VERSION` and `self_update_main VERSION [--yes]`.

- [ ] **Step 1: Write exact self-update and rollback tests**

Create candidate launchers in the test temporary directory by changing only
the embedded version, then stub `download_file` to copy the selected candidate
when the exact raw tag URL is requested. Assert:

```bash
self_update_main 0.3.0 --yes
assert_eq 'Wari 0.3.0' "$("$PROJECT/wari" --version)" \
    'self-update publishes the exact tagged launcher'
assert_contains "$(<"$PROJECT/wari.lock")" 'wari_version=0.3.0' \
    'self-update publishes a lock bound to the candidate launcher'
assert_contains "$(<"$PROJECT/wari.lock")" 'composer_version=2.8.11' \
    'self-update preserves the exact Composer selection'
```

Also cover:

- exact URL `https://raw.githubusercontent.com/wednesdaymoonlab/wari/v0.3.0/wari`;
- missing/invalid/prerelease target version;
- candidate embedded-version mismatch;
- candidate lock generation receives the current exact FrankenPHP, Composer,
  and Linux build values;
- current locally modified launcher rejected before download;
- confirmation decline is a successful no-op;
- `.wari/` marker remains byte-for-byte unchanged;
- simulated second publication failure restores both old launcher and old lock;
- invalid candidate pair never publishes;
- success prints the version comparison, Git-review instruction, and explicit
  `./wari setup` instruction.

For rollback simulation, source `wari` in a subshell and override `mv()` so it
delegates to `command mv` except when the source is the staged candidate lock
and destination is the public `wari.lock`; return 73 at that exact point. Then
assert both public file digests equal their pre-call values.

- [ ] **Step 2: Run update tests and confirm the red state**

Run:

```bash
bash tests/test-update.sh
```

Expected: non-zero because `self_update_main` and the `self-update` dispatcher
case do not exist.

- [ ] **Step 3: Implement candidate acquisition and transactional publication**

Validate the target before staging and construct only this URL:

```bash
url="https://raw.githubusercontent.com/wednesdaymoonlab/wari/v$target_version/wari"
```

After downloading/chmod, require:

```bash
candidate_version="$(bash "$staging/wari" --version-value)" || return 1
[[ "$candidate_version" == "$target_version" ]] || {
    die 'downloaded Wari launcher version does not match the requested tag'
    return 1
}
```

Invoke the candidate generator with all three current dependency selections as
exact values, then validate the pair. Back up both public files into staging,
publish launcher first and lock second, preserve mode 755, validate the public
pair, and clear backup state only after success. Cleanup must restore both files
in reverse publication order and retain backup paths if restoration fails.

Add the dispatcher case:

```bash
self-update)
    shift
    self_update_main "$@"
    ;;
```

Update usage output to say `self-update VERSION` and keep `update` explicitly
dependency-only.

- [ ] **Step 4: Run focused rollback and launcher tests**

Run:

```bash
bash -n wari
bash tests/test-update.sh
bash tests/test-launcher.sh
```

Expected: zero failures including rollback restoration and pre-setup command
behavior.

- [ ] **Step 5: Inspect the task diff**

Run:

```bash
git diff --check
git status --short
```

Expected: launcher and update/launcher tests changed; nothing staged.

---

### Task 5: Maintainer Generator and Repository Lock

**Files:**
- Rewrite: `tools/generate-lock.sh`
- Modify: `tests/test-lock.sh`
- Modify: `wari.lock`

**Interfaces:**
- Consumes: Task 1 hidden `wari --generate-lock` interface.
- Produces: `tools/generate-lock.sh <wari-version> <frankenphp-version> <composer-version> <static|gnu>` with canonical lock on stdout and no duplicate resolver implementation.

- [ ] **Step 1: Write delegation tests for the maintainer tool**

Retain validation tests for four exact arguments and add a fake local `wari`
which records its argv. Assert that the wrapper invokes this shape:

```text
--generate-lock <temporary-output>
--frankenphp 1.12.7
--composer 2.8.11
--linux-build static
```

Assert stdout equals the completed generated lock, stderr carries errors, and
the temporary directory is removed after success, failure, `INT`, and `TERM`.
Assert the first argument still has to equal the local launcher's
`--version-value`, preventing a misleading lock version.

- [ ] **Step 2: Run lock tests and confirm the red state**

Run:

```bash
bash tests/test-lock.sh
```

Expected: new delegation assertions fail because the current tool duplicates
FrankenPHP and Composer download/checksum logic.

- [ ] **Step 3: Replace duplicate generator logic with a thin wrapper**

Resolve `CORE_DIR` physically, validate four arguments, compare the requested
Wari version to:

```bash
actual_wari_version="$(bash "$CORE_DIR/wari" --version-value)"
```

Create a private temporary directory with `mktemp -d`, invoke the canonical
generator to `"$temporary/wari.lock"`, and only after success print it with:

```bash
command cat "$temporary/wari.lock"
```

Use exact-path cleanup and signal traps; do not retain curl, JSON, release asset,
or checksum parser implementations in this wrapper.

- [ ] **Step 4: Regenerate the repository lock from exact current selections**

Read current exact values first:

```bash
awk -F= '$1 == "frankenphp_version" || $1 == "composer_version" || \
  $1 == "linux_build" { print }' wari.lock
```

Then generate a candidate outside the repository with the canonical launcher
using those exact values:

```bash
./wari --generate-lock /tmp/wari.lock.new \
  --frankenphp 1.12.7 \
  --composer 2.8.11 \
  --linux-build static
```

Validate it and inspect the exact generated difference:

```bash
./wari --validate-pair /tmp/wari.lock.new
diff -u wari.lock /tmp/wari.lock.new
```

If the exact versions in the pre-task lock differ, substitute those observed
values rather than silently changing dependency versions. Apply that exact
candidate content to `wari.lock` with `apply_patch`, then run
`./wari --validate-pair ./wari.lock`. This step requires real official metadata
access but does not download runtime binaries.

- [ ] **Step 5: Run lock and setup regressions**

Run:

```bash
bash -n tools/generate-lock.sh
bash tests/test-lock.sh
bash tests/test-setup.sh
bash wari --validate-pair wari.lock
```

Expected: syntax success, zero test failures, and repository launcher/lock pair
validation success.

- [ ] **Step 6: Inspect the task diff**

Run:

```bash
git diff --check
git status --short
```

Expected: canonical launcher digest recorded in `wari.lock`, generator wrapper
simplified, and nothing staged.

---

### Task 6: Live Workflow, CI, and Documentation

**Files:**
- Modify: `tests/test-live-install.sh`
- Modify: `.github/workflows/test.yml`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-07-wari-project-local-team-runtime-design.md`

**Interfaces:**
- Consumes: public initializer, `setup`, dependency `update`, and exact `self-update` contracts from Tasks 1-5.
- Produces: documented user/maintainer workflows and a live test that does not depend on a Wari GitHub Release.

- [ ] **Step 1: Make the live test initialize from the working source**

Replace its initializer test double/copy of the repository lock with:

```bash
(
    cd "$PROJECT"
    bash "$CORE_DIR/install.sh" --yes \
        --local-source "$CORE_DIR" \
        --frankenphp "$LOCK_FRANKENPHP_VERSION" \
        --composer "$LOCK_COMPOSER_VERSION" \
        --linux-build "$WARI_LINUX_BUILD"
)
```

Retain real `./wari setup --yes`, PHP/Composer/FrankenPHP version checks,
create-project, Composer child-process checks, HTTP smoke testing, exact cleanup,
and both static/GNU behavior. Add assertions that initialization did not create
`.wari/` and that the generated lock validates before setup.

- [ ] **Step 2: Update CI descriptions and keep tag-independent coverage**

Keep the four-platform offline matrix and five-entry live matrix. Ensure the
offline job runs every shell suite, and rename the live step to communicate that
it generates a lock from local source before installing real runtime artifacts.
Do not add a GitHub Release or tag prerequisite to CI.

- [ ] **Step 3: Rewrite user and maintainer documentation**

Update README examples to include:

```bash
# Install: generates wari.lock, but does not create .wari/
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup

# Update runtime dependency selections only
./wari update
./wari update --frankenphp 1.12.7 --composer 2.10.3

# Update the launcher from an exact immutable tag
./wari self-update 0.3.0

# Develop/test before a Wari tag exists
bash ../../core/install.sh --local-source ../../core
```

State explicitly that `wari.lock` is generated during initialization and should
be committed, `.wari/` is machine-local and ignored, omitted update versions
resolve latest stable, update preserves Linux build, self-update preserves exact
dependency versions, setup remains explicit, and GitHub Releases are optional.

Document tag publication as a maintainer-run Git operation after tests and
source push; do not imply Wari runs Git commands.

- [ ] **Step 4: Mark the historical design as partially superseded**

Add a short notice directly below the old design title linking to:

```text
docs/superpowers/specs/2026-09-07-wari-generated-lock-tag-distribution-design.md
```

State that the newer spec replaces initialization and update distribution only;
all runtime/setup guarantees in the old document remain active.

- [ ] **Step 5: Run offline documentation-adjacent regressions**

Run:

```bash
bash tests/test-initializer.sh
bash tests/test-launcher.sh
bash tests/test-update.sh
bash -n tests/test-live-install.sh
git diff --check
```

Expected: all tests report zero failures, live script parses, docs contain no
active instruction requiring GitHub Release assets, and whitespace checks pass.

- [ ] **Step 6: Inspect the task diff**

Run:

```bash
git status --short
git diff --stat
```

Expected: implementation, tests, docs, workflow, generated lock, and approved
spec/plan are unstaged.

---

### Task 7: Complete Verification and Security Regression

**Files:**
- Verify: all modified files
- Modify only if a failing test exposes a defect in the approved behavior

**Interfaces:**
- Consumes: every prior task's public and hidden contracts.
- Produces: evidence that offline, cross-component, and live behaviors satisfy the approved spec.

- [ ] **Step 1: Run syntax validation on every maintained shell file**

Run:

```bash
bash -n wari
bash -n install.sh
bash -n tools/generate-lock.sh
for test_file in tests/test-*.sh; do bash -n "$test_file"; done
```

Expected: every command exits zero with no syntax diagnostics.

- [ ] **Step 2: Run the complete offline suite**

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
```

Expected: each script ends with `0 failures` and exits zero.

- [ ] **Step 3: Run explicit security/contract spot checks**

In a new temporary project initialized through `--local-source`, verify:

```bash
test ! -e .wari
./wari --validate-pair wari.lock
! ./wari composer --version
```

Capture stderr from the last command and require `./wari setup`. Also inspect
the fake-curl request log from offline tests to require no URL containing:

```text
api.github.com/repos/wednesdaymoonlab/wari/releases
github.com/wednesdaymoonlab/wari/releases/download
```

Require the only remote Wari launcher pattern to be:

```text
https://raw.githubusercontent.com/wednesdaymoonlab/wari/v<SEMVER>/wari
```

- [ ] **Step 4: Run the opt-in live end-to-end suite**

Run:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

Expected: real metadata resolution, local-source initialization, checksum-
verified setup, PHP/Composer/FrankenPHP versions, create-project, Composer child
processes, and loopback HTTP smoke checks all succeed. This operation requires
network access and may request sandbox escalation.

- [ ] **Step 5: Validate the final tracked pair and working tree**

Run:

```bash
bash wari --validate-pair wari.lock
git diff --check
git status --short --branch
git diff --stat
```

Expected: pair validation and whitespace checks succeed; branch is `main`; all
intended changes remain unstaged; there are no unrelated modifications.

- [ ] **Step 6: Review against every spec section**

Read the final diff beside the approved spec and confirm these exact outcomes:

- initialization downloads a tag launcher and generates a lock;
- local-source mode works without a Wari tag;
- runtime commands before setup remain network-free failures;
- update changes only dependency lock content;
- self-update requires an exact version and preserves dependency selections;
- Linux build default/preservation rules hold;
- no code path requires a GitHub Release;
- setup/runtime safety and rollback tests remain green;
- README and CI describe the implemented behavior; and
- the final response reports verification evidence without claiming any commit,
  push, tag, or release was created.
