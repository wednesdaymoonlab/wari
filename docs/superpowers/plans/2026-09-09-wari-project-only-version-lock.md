# Wari Project-Only Version Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `wari.lock` a project-owned five-field version lock while preserving live download verification, format 1 migration, and the Wari 0.3.0 self-update handshake.

**Architecture:** The launcher will parse strict format 1 and format 2 locks, but project identity will be checked by Wari version only. Format 2 generation resolves versions without persisting hashes; setup independently fetches official integrity metadata for the exact locked versions, verifies the downloaded bytes, and records the verified hashes only in `.wari/manifest.json`. Core help, version, and supplied-path internal operations run without a repository lock, while all project operations remain lock-gated.

**Tech Stack:** Bash 3.2-compatible shell, curl, awk, sed, GitHub Releases JSON, Composer HTTPS metadata, shell test harness, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-09-wari-project-only-version-lock-design.md`

## Global Constraints

- Target Wari version is exactly `0.4.0`.
- New locks contain exactly `lock_version`, `wari_version`, `frankenphp_version`, `composer_version`, and `linux_build`, in that order.
- Accept strict legacy format 1 locks, but never use their stored checksums as installation trust inputs.
- `setup` verifies each download against official metadata fetched during that setup run and never rewrites `wari.lock`.
- A matching `.wari/manifest.json` returns without metadata or artifact network requests.
- Preserve HTTPS host/redirect allowlists, atomic publication, rollback, signal handling, runtime layout, and `.wari/` ignore behavior.
- Preserve Bash 3.2 compatibility: no associative arrays, namerefs, or Bash 4-only syntax.
- Preserve all current unstaged CLI color, C2 ASCII-logo, documentation, and test changes.
- The repository instructions prohibit `git add`, `git commit`, and `git push`; every task ends with an unstaged review checkpoint instead of a commit.
- Do not delete the core `wari.lock` until every offline test has been decoupled from it.

## File Map

- `wari`: dual-format parsing, version identity, lock generation, setup metadata resolution, update/self-update migration, and lock-free command routing.
- `install.sh`: initializer always requests format 2 and validates launcher version against its staged lock.
- `tools/generate-lock.sh`: maintainer wrapper explicitly requests format 2.
- `tests/test-helper.sh`: canonical format 1 and format 2 fixture writers shared by every suite.
- `tests/test-lock.sh`: parser, generator, asset metadata, and 0.3.0 compatibility contract.
- `tests/test-launcher.sh`: lock-free core commands and project-command lock gating.
- `tests/test-setup.sh`: same-run metadata verification, changed upstream digest handling, manifest evidence, idempotence, rollback, and lock immutability.
- `tests/test-update.sh`: dependency-update format migration and no-change behavior.
- `tests/test-initializer.sh`, `tests/test-installer.sh`: exact five-key project initialization and publication safety.
- `tests/test-wrappers.sh`, `tests/test-create-project.sh`, `tests/test-service.sh`: project fixtures independent from a core lock.
- `tests/test-live-install.sh`: initializer-driven live runtime and Laravel smoke test without reading a core lock.
- `README.md`: version-lock semantics, trust model, migration, and troubleshooting.
- `wari.lock`: removed after fixture migration.

---

### Task 1: Shared Lock Fixtures and Lock-Free Core Commands

**Files:**
- Modify: `tests/test-helper.sh`
- Modify: `tests/test-launcher.sh`
- Modify: `wari` (`launcher_main`, project lock error path)

**Interfaces:**
- Produces: `write_format2_lock PATH [WARI_VERSION] [FRANKENPHP_VERSION] [COMPOSER_VERSION] [LINUX_BUILD]` returning a canonical five-line lock.
- Produces: `write_format1_lock PATH LAUNCHER [WARI_VERSION] [FRANKENPHP_VERSION] [COMPOSER_VERSION] [LINUX_BUILD]` returning a strict legacy fixture with deterministic lowercase hashes.
- Produces: `require_project_lock PROJECT_ROOT LAUNCHER` returning nonzero with initialization guidance when the adjacent lock is absent or invalid.
- Consumes: existing `assert_eq`, `assert_contains`, `assert_not_contains`, and `assert_fails` test helpers.

- [x] **Step 1: Add reusable lock fixture writers.**

```bash
write_format2_lock() {
    local path="$1"
    local wari_version="${2:-0.4.0}"
    local frankenphp_version="${3:-1.12.7}"
    local composer_version="${4:-2.8.11}"
    local linux_build="${5:-static}"

    printf '%s\n' \
        'lock_version=2' \
        "wari_version=$wari_version" \
        "frankenphp_version=$frankenphp_version" \
        "composer_version=$composer_version" \
        "linux_build=$linux_build" >"$path"
}

write_format1_lock() {
    local path="$1" launcher="$2"
    local wari_version="${3:-0.4.0}"
    local frankenphp_version="${4:-1.12.7}"
    local composer_version="${5:-2.8.11}"
    local linux_build="${6:-static}"
    local launcher_sha

    if command -v sha256sum >/dev/null 2>&1; then
        launcher_sha="$(sha256sum "$launcher")"
    else
        launcher_sha="$(shasum -a 256 "$launcher")"
    fi
    launcher_sha="${launcher_sha%%[[:space:]]*}"
    {
        printf '%s\n' 'lock_version=1' "wari_version=$wari_version" \
            "frankenphp_version=$frankenphp_version" \
            "composer_version=$composer_version" "linux_build=$linux_build"
        printf 'wari_sha256=%s\n' "$launcher_sha"
        printf 'composer_installer_sha384=%096d\n' 0
        printf 'composer_sha256=%064d\n' 1
        printf 'frankenphp_linux_x86_64_sha256=%064d\n' 2
        printf 'frankenphp_linux_arm64_sha256=%064d\n' 3
        printf 'frankenphp_macos_x86_64_sha256=%064d\n' 4
        printf 'frankenphp_macos_arm64_sha256=%064d\n' 5
    } >"$path"
}
```

- [x] **Step 2: Write launcher tests that run core commands with no adjacent lock and reject project commands before network access.**

```bash
LOCK_FREE="$LAUNCHER_TMP/lock-free"
NO_NETWORK_BIN="$LAUNCHER_TMP/no-network-bin"
mkdir -p "$LOCK_FREE"
mkdir -p "$NO_NETWORK_BIN"
cp "$CORE_DIR/wari" "$LOCK_FREE/wari"
chmod 755 "$LOCK_FREE/wari"
cat >"$NO_NETWORK_BIN/curl" <<'NO_NETWORK_CURL'
#!/usr/bin/env bash
printf 'unexpected network request\n' >&2
exit 97
NO_NETWORK_CURL
chmod 755 "$NO_NETWORK_BIN/curl"

assert_contains "$(bash "$LOCK_FREE/wari" --help)" 'Usage:' \
    'core help works without wari.lock'
assert_eq 'Wari 0.4.0' "$(bash "$LOCK_FREE/wari" --version)" \
    'core version works without wari.lock'

set +e
MISSING_OUTPUT="$(PATH="$NO_NETWORK_BIN:$PATH" bash "$LOCK_FREE/wari" setup 2>&1)"
MISSING_STATUS=$?
set -e
assert_eq '1' "$MISSING_STATUS" 'project setup rejects a missing lock'
assert_contains "$MISSING_OUTPUT" 'initialize Wari in this PHP project' \
    'missing lock explains project initialization'
```

- [x] **Step 3: Run the launcher test and confirm the new assertions fail.**

Run: `bash tests/test-launcher.sh`

Expected: failures show that `--help` and `--version` still pass through adjacent-lock validation and that the missing-lock message is not focused.

- [x] **Step 4: Move lock-independent dispatch before project validation and add the focused gate.**

```bash
require_project_lock() {
    local project_root="$1" launcher="$2"

    if [[ ! -f "$project_root/wari.lock" || -L "$project_root/wari.lock" ]]; then
        die 'wari.lock is missing; initialize Wari in this PHP project with install.sh'
        return 1
    fi
    validate_launcher_lock_version "$launcher" "$project_root/wari.lock"
}
```

In `launcher_main`, keep `--version-value`, `--validate-pair`, and `--generate-lock` first; dispatch `''|help|--help|-h` and `--version` next; call `require_project_lock` once before dispatching `setup`, `update`, `self-update`, runtime wrappers, and non-help service operations. Keep `service --help` available before runtime setup, but require the project lock because it is a project-facing command.

- [x] **Step 5: Re-run launcher tests and inspect the scoped diff.**

Run: `bash tests/test-launcher.sh && git diff --check`

Expected: all launcher assertions pass and `git diff --check` is silent.

Review checkpoint: inspect `git diff -- wari tests/test-helper.sh tests/test-launcher.sh`; leave all files unstaged.

---

### Task 2: Strict Dual-Format Parser and Version-Only Launcher Identity

**Files:**
- Modify: `tests/test-lock.sh`
- Modify: `wari` (`reset_lock_state`, `assign_lock_value`, `validate_complete_lock`, `parse_lock`, `validate_launcher_pair`, `select_locked_asset`)

**Interfaces:**
- Produces: `validate_format_1_lock` and `validate_format_2_lock`, each reading the existing `LOCK_*` and `SEEN_*` globals.
- Produces: `validate_launcher_lock_version LAUNCHER LOCK_PATH`, parsing the supplied lock and comparing `bash LAUNCHER --version-value` with `LOCK_WARI_VERSION`.
- Produces: `select_locked_asset`, setting only `ASSET_NAME`; setup metadata resolution will set `ASSET_URL` and `ASSET_SHA256` in Task 4.
- Consumes: fixture writers from Task 1.

- [x] **Step 1: Replace the single-format parser tests with explicit format 1 and format 2 cases.**

```bash
FORMAT2_LOCK="$LOCK_TMP/format2.lock"
write_format2_lock "$FORMAT2_LOCK"
parse_lock "$FORMAT2_LOCK"
assert_eq '2' "$LOCK_VERSION" 'accepts canonical format 2'
assert_eq '0.4.0' "$LOCK_WARI_VERSION" 'loads format 2 Wari version'

FORMAT2_WITH_HASH="$LOCK_TMP/format2-with-hash.lock"
cp "$FORMAT2_LOCK" "$FORMAT2_WITH_HASH"
printf 'wari_sha256=%064d\n' 0 >>"$FORMAT2_WITH_HASH"
assert_fails 'format 2 rejects legacy checksum keys' parse_lock "$FORMAT2_WITH_HASH"

FORMAT1_LOCK="$LOCK_TMP/format1.lock"
write_format1_lock "$FORMAT1_LOCK" "$CORE_DIR/wari"
parse_lock "$FORMAT1_LOCK"
assert_eq '1' "$LOCK_VERSION" 'accepts strict legacy format 1'
```

Add the remaining strictness cases with explicit mutations:

```bash
for case_name in missing duplicate unknown blank whitespace bad-semver bad-build \
    incomplete-v1 unsupported; do
    candidate="$LOCK_TMP/$case_name.lock"
    case "$case_name" in
        missing) sed '/^composer_version=/d' "$FORMAT2_LOCK" >"$candidate" ;;
        duplicate) { cat "$FORMAT2_LOCK"; printf 'wari_version=0.4.0\n'; } >"$candidate" ;;
        unknown) { cat "$FORMAT2_LOCK"; printf 'download_url=https://example.test/x\n'; } >"$candidate" ;;
        blank) { cat "$FORMAT2_LOCK"; printf '\n'; } >"$candidate" ;;
        whitespace) sed 's/^linux_build=.*/linux_build=static build/' "$FORMAT2_LOCK" >"$candidate" ;;
        bad-semver) sed 's/^composer_version=.*/composer_version=2.8.11-rc1/' "$FORMAT2_LOCK" >"$candidate" ;;
        bad-build) sed 's/^linux_build=.*/linux_build=dynamic/' "$FORMAT2_LOCK" >"$candidate" ;;
        incomplete-v1) sed '/^composer_sha256=/d' "$FORMAT1_LOCK" >"$candidate" ;;
        unsupported) sed 's/^lock_version=.*/lock_version=3/' "$FORMAT2_LOCK" >"$candidate" ;;
    esac
    assert_fails "rejects $case_name lock input" parse_lock "$candidate"
done

CONTROL_LOCK="$LOCK_TMP/control.lock"
printf 'lock_version=2\nwari_version=0.4.0\r\nfrankenphp_version=1.12.7\ncomposer_version=2.8.11\nlinux_build=static\n' \
    >"$CONTROL_LOCK"
assert_fails 'rejects a control character in a lock value' parse_lock "$CONTROL_LOCK"
```

- [x] **Step 2: Add identity tests proving hashes are ignored and versions are enforced.**

```bash
LEGACY_CHANGED_SHA="$LOCK_TMP/legacy-changed-sha.lock"
write_format1_lock "$LEGACY_CHANGED_SHA" "$CORE_DIR/wari"
sed 's/^wari_sha256=.*/wari_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$LEGACY_CHANGED_SHA" >"$LOCK_TMP/legacy-version-only.lock"
assert_eq '0' "$(validate_launcher_lock_version "$CORE_DIR/wari" \
    "$LOCK_TMP/legacy-version-only.lock" >/dev/null 2>&1; printf '%s' "$?")" \
    'legacy launcher checksum is not an identity input'

WRONG_VERSION="$LOCK_TMP/wrong-version.lock"
write_format2_lock "$WRONG_VERSION" 9.9.9
assert_fails 'launcher identity still requires matching Wari version' \
    validate_launcher_lock_version "$CORE_DIR/wari" "$WRONG_VERSION"
```

- [x] **Step 3: Run the lock tests and verify the format 2 cases fail.**

Run: `bash tests/test-lock.sh`

Expected: format 2 is rejected by the format 1-only validator and the renamed version validator is missing.

- [x] **Step 4: Split required-key validation by lock version.**

```bash
validate_complete_lock() {
    case "$LOCK_VERSION" in
        1) validate_format_1_lock ;;
        2) validate_format_2_lock ;;
        *) die "unsupported Wari lock version: $LOCK_VERSION"; return 1 ;;
    esac
}

validate_format_2_lock() {
    [[ "$SEEN_LOCK_VERSION" -eq 1 &&
       "$SEEN_WARI_VERSION" -eq 1 &&
       "$SEEN_FRANKENPHP_VERSION" -eq 1 &&
       "$SEEN_COMPOSER_VERSION" -eq 1 &&
       "$SEEN_LINUX_BUILD" -eq 1 ]] || {
        die 'Wari lock is missing one or more required keys'
        return 1
    }
    [[ "$SEEN_WARI_SHA256" -eq 0 &&
       "$SEEN_COMPOSER_INSTALLER_SHA384" -eq 0 &&
       "$SEEN_COMPOSER_SHA256" -eq 0 &&
       "$SEEN_FRANKENPHP_LINUX_X86_64_SHA256" -eq 0 &&
       "$SEEN_FRANKENPHP_LINUX_ARM64_SHA256" -eq 0 &&
       "$SEEN_FRANKENPHP_MACOS_X86_64_SHA256" -eq 0 &&
       "$SEEN_FRANKENPHP_MACOS_ARM64_SHA256" -eq 0 ]] || {
        die 'Wari lock format 2 does not allow checksum keys'
        return 1
    }
    validate_lock_versions_and_build
}
```

Keep format 1's exact 12-key and lowercase hash validation in `validate_format_1_lock`. Extract the three semver checks and build enum into `validate_lock_versions_and_build` so both formats share identical lexical validation.

- [x] **Step 5: Replace byte identity with version identity and make asset selection checksum-free.**

```bash
validate_launcher_lock_version() {
    local launcher="$1" lock="$2" reported_version

    parse_lock "$lock" || return 1
    reported_version="$(bash "$launcher" --version-value)" || return 1
    [[ "$reported_version" == "$LOCK_WARI_VERSION" ]] || {
        die 'Wari launcher version does not match wari.lock'
        return 1
    }
}
```

Retain `--validate-pair` as a hidden compatibility spelling, but route it to `validate_launcher_lock_version`. Remove `ASSET_SHA256` assignments from `select_locked_asset`; preserve all four OS/architecture names and Linux `static|gnu` selection.

- [x] **Step 6: Run parser and launcher suites.**

Run: `bash tests/test-lock.sh && bash tests/test-launcher.sh && git diff --check`

Expected: both lock formats parse strictly, modified legacy hashes do not block version identity, wrong Wari versions fail, and all asset-name assertions pass.

Review checkpoint: inspect `git diff -- wari tests/test-lock.sh tests/test-launcher.sh`; leave changes unstaged.

---

### Task 3: Format 2 Generator with the Wari 0.3.0 Compatibility Default

**Files:**
- Modify: `tests/test-lock.sh`
- Modify: `wari` (`generate_lock_file`, `generate_lock_main`)
- Modify: `tools/generate-lock.sh`

**Interfaces:**
- Produces: `generate_lock_file LAUNCHER OUTPUT FRANKENPHP_REQUEST COMPOSER_REQUEST LINUX_BUILD LOCK_VERSION`.
- Extends hidden CLI: `--generate-lock OUTPUT [--frankenphp VERSION] [--composer VERSION] [--linux-build static|gnu] [--lock-version 1|2]`.
- Contract: omitted `--lock-version` means `1`; all Wari 0.4-owned callers explicitly pass `--lock-version 2`.

- [x] **Step 1: Add generator tests for exact format 2 output and strict option parsing.**

```bash
FORMAT2_GENERATED="$LOCK_TMP/generated-v2.lock"
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    bash "$CORE_DIR/wari" --generate-lock "$FORMAT2_GENERATED" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static \
    --lock-version 2
assert_eq "$(printf '%s\n' \
    'lock_version=2' \
    'wari_version=0.4.0' \
    'frankenphp_version=1.12.7' \
    'composer_version=2.8.11' \
    'linux_build=static')" "$(<"$FORMAT2_GENERATED")" \
    'format 2 generator writes exactly five ordered keys'

assert_fails 'generator rejects duplicate lock version options' \
    bash "$CORE_DIR/wari" --generate-lock "$LOCK_TMP/rejected.lock" \
    --lock-version 2 --lock-version 2
assert_fails 'generator rejects unsupported lock format' \
    bash "$CORE_DIR/wari" --generate-lock "$LOCK_TMP/rejected.lock" \
    --lock-version 3
```

- [x] **Step 2: Add a compatibility parser in the test that models the released 0.3.0 caller.**

```bash
validate_v030_candidate_lock() {
    local lock="$1"
    [[ "$(sed -n '1p' "$lock")" == 'lock_version=1' ]] || return 1
    [[ "$(wc -l <"$lock" | tr -d ' ')" == '12' ]] || return 1
    grep -Eq '^wari_sha256=[0-9a-f]{64}$' "$lock" || return 1
    grep -Eq '^composer_installer_sha384=[0-9a-f]{96}$' "$lock" || return 1
    grep -Eq '^frankenphp_macos_arm64_sha256=[0-9a-f]{64}$' "$lock"
}

V030_CANDIDATE="$LOCK_TMP/v030-candidate.lock"
PATH="$CANON_FAKE_BIN:$PATH" WARI_TEST_FIXTURES="$TEST_DIR/fixtures" \
    bash "$CORE_DIR/wari" --generate-lock "$V030_CANDIDATE" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static
assert_eq '0' "$(validate_v030_candidate_lock "$V030_CANDIDATE"; printf '%s' "$?")" \
    'omitted lock version remains consumable by Wari 0.3.0'
parse_lock "$V030_CANDIDATE"
assert_eq '1' "$LOCK_VERSION" 'Wari 0.4 reads the compatibility lock'
```

- [x] **Step 3: Run lock tests and confirm explicit format 2 generation fails.**

Run: `bash tests/test-lock.sh`

Expected: `--lock-version` is reported as unknown and no five-key lock is produced.

- [x] **Step 4: Add lock-version parsing and branch generation.**

```bash
local lock_version='1'
local seen_lock_version=0

--lock-version)
    [[ "$seen_lock_version" -eq 0 && "$#" -ge 2 ]] || {
        die 'invalid or duplicate --lock-version option'; return 2;
    }
    seen_lock_version=1
    lock_version="$2"
    [[ "$lock_version" == 1 || "$lock_version" == 2 ]] || {
        die "unsupported generated lock version: $lock_version"; return 2;
    }
    shift 2
    ;;
```

For format 2, resolve the requested/latest stable release versions but skip Composer installer and PHAR checksum endpoints and skip launcher hashing. Write the five ordered keys and validate with `validate_launcher_lock_version`. For format 1, preserve the existing metadata downloads and exact 12-line output so a 0.3.0 caller can validate it.

- [x] **Step 5: Make maintainer tooling explicitly request format 2.**

```bash
bash "$core_dir/wari" --generate-lock "$temporary/wari.lock" \
    --frankenphp "$frankenphp_version" \
    --composer "$composer_version" \
    --linux-build "$linux_build" \
    --lock-version 2 || return 1
```

Update the delegation assertion to require the exact `--lock-version` and `2` arguments.

- [x] **Step 6: Run lock tests and inspect output manually.**

Run: `bash tests/test-lock.sh && bash tools/generate-lock.sh 0.4.0 1.12.7 2.8.11 static | sed -n '1,6p' && git diff --check`

Expected: tests pass; the tool prints exactly five lock lines and no sixth line.

Review checkpoint: inspect `git diff -- wari tools/generate-lock.sh tests/test-lock.sh`; leave changes unstaged.

---

### Task 4: Setup Integrity Metadata Resolved in the Same Run

**Files:**
- Modify: `tests/test-setup.sh`
- Modify: `tests/fixtures/frankenphp-release.json` only if the current fixture lacks an official `digest` for every tested asset
- Modify: `wari` (`setup_main`, metadata resolver, installers, `write_manifest`)

**Interfaces:**
- Produces: `resolve_setup_integrity_metadata STAGING`, using parsed lock/platform globals and setting `ASSET_NAME`, `ASSET_URL`, `ASSET_SHA256`, `VERIFIED_COMPOSER_INSTALLER_SHA384`, and `VERIFIED_COMPOSER_SHA256`.
- Consumes: `parse_frankenphp_release`, `read_checksum_value`, `download_file`, `select_locked_asset`, and exact versions from `parse_lock`.
- Changes: `install_locked_frankenphp STAGING` and `install_locked_composer STAGING` consume the `VERIFIED_*` globals, never `LOCK_*SHA*` fields.

- [x] **Step 1: Add a setup fixture curl that logs metadata and artifact requests separately.**

```bash
fixture_download_file() {
    local url="$1" destination="$2"
    printf '%s\n' "$url" >>"$SETUP_REQUEST_LOG"
    case "$url" in
        https://api.github.com/repos/php/frankenphp/releases/tags/v1.12.7)
            cp "$TEST_DIR/fixtures/frankenphp-release.json" "$destination" ;;
        https://composer.github.io/installer.sig)
            printf '%s\n' "$FIXTURE_INSTALLER_SHA384" >"$destination" ;;
        https://getcomposer.org/download/2.8.11/composer.phar.sha256sum)
            printf '%s  composer.phar\n' "$FIXTURE_COMPOSER_SHA256" >"$destination" ;;
        https://github.com/php/frankenphp/releases/download/v1.12.7/frankenphp-linux-x86_64)
            cp "$FIXTURE_FRANKENPHP" "$destination" ;;
        https://getcomposer.org/installer)
            cp "$FIXTURE_INSTALLER" "$destination" ;;
        *) return 88 ;;
    esac
}
```

- [x] **Step 2: Add tests for changed official digest, same-run mismatch, lock immutability, and idempotence.**

Create a format 1 lock whose stored dependency hashes are valid syntax but differ from fixture bytes. Run setup with fixture metadata whose `digest` matches the fixture asset and assert success. Save `LOCK_BEFORE="$(calculate_checksum sha256 "$PROJECT/wari.lock")"` and assert the post-setup digest equals it. Then change the downloaded asset bytes without changing metadata and assert setup fails while the prior runtime and lock remain unchanged. Finally re-run setup with a `download_file` replacement that always returns 97 and assert success, proving a matching manifest performs no network work.

```bash
assert_eq "$LOCK_BEFORE" "$(calculate_checksum sha256 "$PROJECT/wari.lock")" \
    'setup leaves the project lock byte-for-byte unchanged'
assert_contains "$(<"$PROJECT/.wari/manifest.json")" \
    "\"asset_sha256\": \"$FIXTURE_FRANKENPHP_SHA256\"" \
    'manifest records the digest verified in this setup run'
assert_contains "$(<"$PROJECT/.wari/manifest.json")" \
    "\"composer_sha256\": \"$FIXTURE_COMPOSER_SHA256\"" \
    'manifest records the Composer digest verified in this setup run'
```

- [x] **Step 3: Run setup tests and verify they fail because lock hashes are still trusted.**

Run: `bash tests/test-setup.sh`

Expected: the changed-official-digest case fails with the legacy expected hash and the metadata request log lacks same-run checksum retrieval.

- [x] **Step 4: Implement the same-run resolver before artifact downloads.**

```bash
resolve_setup_integrity_metadata() {
    local staging="$1"
    local release_json="$staging/frankenphp-release.json"
    local installer_sig="$staging/composer-installer.sig"
    local composer_sum="$staging/composer.sha256sum"

    download_file \
        "https://api.github.com/repos/php/frankenphp/releases/tags/v$LOCK_FRANKENPHP_VERSION" \
        "$release_json" || return 1
    parse_frankenphp_release "$release_json" "$LOCK_FRANKENPHP_VERSION" \
        "$LOCK_LINUX_BUILD" || return 1
    select_resolved_asset_metadata "$ASSET_NAME" || return 1

    download_file 'https://composer.github.io/installer.sig' "$installer_sig" || return 1
    VERIFIED_COMPOSER_INSTALLER_SHA384="$(read_checksum_value \
        "$installer_sig" 96 'Composer installer')" || return 1
    download_file \
        "https://getcomposer.org/download/$LOCK_COMPOSER_VERSION/composer.phar.sha256sum" \
        "$composer_sum" || return 1
    VERIFIED_COMPOSER_SHA256="$(read_checksum_value \
        "$composer_sum" 64 Composer)" || return 1
}
```

`select_resolved_asset_metadata` maps the current platform to the already validated release digest, sets `ASSET_URL`, and keeps `ASSET_SHA256` lowercase. `parse_frankenphp_release` and `read_frankenphp_release_asset` continue to require exactly one record per expected asset, an official `browser_download_url`, and a lowercase `sha256:` digest instead of accepting the first match.

Implement the mapping after `parse_frankenphp_release` has validated all four records:

```bash
select_resolved_asset_metadata() {
    select_locked_asset || return 1
    case "$PLATFORM_OS/$PLATFORM_ARCH" in
        linux/x86_64)
            ASSET_SHA256="$RESOLVED_FRANKENPHP_LINUX_X86_64_SHA256" ;;
        linux/arm64)
            ASSET_SHA256="$RESOLVED_FRANKENPHP_LINUX_ARM64_SHA256" ;;
        darwin/x86_64)
            ASSET_SHA256="$RESOLVED_FRANKENPHP_MACOS_X86_64_SHA256" ;;
        darwin/arm64)
            ASSET_SHA256="$RESOLVED_FRANKENPHP_MACOS_ARM64_SHA256" ;;
        *) return 1 ;;
    esac
    ASSET_URL="https://github.com/php/frankenphp/releases/download/v$LOCK_FRANKENPHP_VERSION/$ASSET_NAME"
}
```

- [x] **Step 5: Point installers and manifest at verified runtime values.**

Use `ASSET_URL` for the FrankenPHP download, `VERIFIED_COMPOSER_INSTALLER_SHA384` for installer verification, and `VERIFIED_COMPOSER_SHA256` for PHAR verification. Write `composer_installer_sha384` and `composer_sha256` from these verified globals to the ignored manifest; keep `asset_sha256`, `checksum_verified: true`, and the complete lock digest.

- [x] **Step 6: Run setup, lock, and launcher suites.**

Run: `bash tests/test-setup.sh && bash tests/test-lock.sh && bash tests/test-launcher.sh && git diff --check`

Expected: all pass, a stale legacy hash is ignored, an in-run mismatch fails closed, setup does not mutate the lock, and idempotent setup performs no network request.

Review checkpoint: inspect `git diff -- wari tests/test-setup.sh tests/fixtures/frankenphp-release.json`; leave changes unstaged.

---

### Task 5: Initializer Creates Only Project-Owned Format 2 Locks

**Files:**
- Modify: `tests/test-initializer.sh`
- Modify: `tests/test-installer.sh`
- Modify: `install.sh` (`generate_staged_lock`, staged validation)

**Interfaces:**
- Consumes: hidden generator option `--lock-version 2` from Task 3.
- Produces: local-source and tagged-source initialization that atomically publishes `wari`, an exact five-key `wari.lock`, and the managed `.gitignore` block without installing `.wari/`.

- [x] **Step 1: Add exact initializer output assertions.**

```bash
EXPECTED_LOCK="$(printf '%s\n' \
    'lock_version=2' \
    'wari_version=0.4.0' \
    'frankenphp_version=1.12.7' \
    'composer_version=2.8.11' \
    'linux_build=static')"
assert_eq "$EXPECTED_LOCK" "$(<"$PROJECT/wari.lock")" \
    'initializer publishes the exact format 2 project lock'
assert_eq '0' "$(test ! -e "$PROJECT/.wari"; printf '%s' "$?")" \
    'initializer leaves runtime setup explicit'
```

Extend existing rollback and signal tests to assert neither a partial launcher nor a partial format 2 lock replaces the prior tracked pair.

- [x] **Step 2: Run initializer and installer tests and verify they fail on format 1 output.**

Run: `bash tests/test-initializer.sh && bash tests/test-installer.sh`

Expected: generated locks contain checksum fields and do not match the five-line expectation.

- [x] **Step 3: Make the initializer explicitly request format 2 and validate by version.**

```bash
generator_args=(
    --generate-lock "$staging/wari.lock"
    --linux-build "$linux_build"
    --lock-version 2
)
```

After generation, invoke `bash "$staging/wari" --validate-pair "$staging/wari.lock"`; its compatibility name now performs version-only validation. Do not read or download a lock from the selected Wari Git tag.

- [x] **Step 4: Run both suites and publication checks.**

Run: `bash tests/test-initializer.sh && bash tests/test-installer.sh && git diff --check`

Expected: exact format 2 locks, explicit runtime setup, local/tag source validation, rollback, and signal cases all pass.

Review checkpoint: inspect `git diff -- install.sh tests/test-initializer.sh tests/test-installer.sh`; leave changes unstaged.

---

### Task 6: Dependency Update and Self-Update Migration

**Files:**
- Modify: `tests/test-update.sh`
- Modify: `wari` (`generate_update_lock`, `update_main`, `generate_self_update_lock`, `self_update_main`)

**Interfaces:**
- Consumes: dual-format parsing and `--lock-version 2`.
- Produces: `update` always emits format 2, including unchanged selections read from format 1.
- Produces: self-updates initiated by 0.4.0 always emit format 2 while preserving dependency versions and Linux build.

- [x] **Step 1: Add update migration tests.**

For a format 1 project, run `update --yes --frankenphp 1.12.7 --composer 2.8.11`; assert it rewrites to the exact five-line format 2 lock even though selected versions did not change. For a format 2 project with unchanged selections, compare inode content/digest before and after and assert the command reports `already current` without rewriting.

```bash
assert_eq '2' "$(sed -n 's/^lock_version=//p' "$PROJECT/wari.lock")" \
    'dependency update migrates format 1 to format 2'
assert_not_contains "$(<"$PROJECT/wari.lock")" '_sha' \
    'migrated dependency lock contains no checksum keys'
```

- [x] **Step 2: Add self-update migration and rollback tests.**

Start from both format 1 and format 2 fixtures. Assert the candidate lock is format 2, `wari_version` equals the target launcher's reported version, dependency/build fields are preserved, `.wari/` remains byte-for-byte untouched, and a post-publication validation failure restores both launcher and lock.

Add an offline compatibility integration that models the released 0.3.0 publication sequence: invoke the 0.4.0 candidate launcher without `--lock-version`, pass its result through `validate_v030_candidate_lock`, atomically move the candidate launcher and format 1 lock into a temporary project, then run the published 0.4.0 launcher with `--validate-pair`. Assert all operations succeed and the next `update --yes` rewrites that lock to format 2.

```bash
bash "$CANDIDATE_WARI" --generate-lock "$HANDSHAKE/wari.lock.next" \
    --frankenphp 1.12.7 --composer 2.8.11 --linux-build static
validate_v030_candidate_lock "$HANDSHAKE/wari.lock.next"
mv "$CANDIDATE_WARI" "$HANDSHAKE/wari"
mv "$HANDSHAKE/wari.lock.next" "$HANDSHAKE/wari.lock"
bash "$HANDSHAKE/wari" --validate-pair "$HANDSHAKE/wari.lock"
PATH="$UPDATE_FAKE_BIN:$PATH" bash "$HANDSHAKE/wari" update --yes \
    --frankenphp 1.12.7 --composer 2.8.11
assert_eq 'lock_version=2' "$(sed -n '1p' "$HANDSHAKE/wari.lock")" \
    'published 0.4 launcher migrates the 0.3 compatibility lock'
```

- [x] **Step 3: Run update tests and verify checksum identity assumptions fail.**

Run: `bash tests/test-update.sh`

Expected: current code expects `LOCK_WARI_SHA256`, emits format 1, and treats unchanged legacy selections as a no-op.

- [x] **Step 4: Explicitly request format 2 from all 0.4 update paths.**

```bash
arguments=(
    --generate-lock "$output"
    --linux-build "$linux_build"
    --lock-version 2
)
```

Apply the same explicit option in `generate_self_update_lock`. Remove `current_wari_sha` and `candidate_wari_sha`; require only equal `wari_version` during dependency update. Preserve the existing atomic backup/publication/signal machinery. The `cmp -s` no-op remains valid for format 2, while any format 1 input necessarily differs and migrates.

- [x] **Step 5: Re-run update, initializer, and lock suites.**

Run: `bash tests/test-update.sh && bash tests/test-initializer.sh && bash tests/test-lock.sh && git diff --check`

Expected: migrations, no-op handling, confirmations, cancellation, rollback, and the 0.3.0 generator handshake all pass.

Review checkpoint: inspect `git diff -- wari tests/test-update.sh`; leave changes unstaged.

---

### Task 7: Remove the Core Lock and Decouple Every Remaining Test

**Files:**
- Modify: `tests/test-wrappers.sh`
- Modify: `tests/test-create-project.sh`
- Modify: `tests/test-service.sh`
- Modify: `tests/test-launcher.sh`
- Modify: `tests/test-setup.sh`
- Modify: `tests/test-update.sh`
- Modify: `tests/test-initializer.sh`
- Modify: `tests/test-live-install.sh`
- Delete: `wari.lock`

**Interfaces:**
- Consumes: `write_format2_lock` and `write_format1_lock` from Task 1.
- Produces: all tests construct consuming-project locks locally; no code or test reads `$CORE_DIR/wari.lock`.

- [x] **Step 1: Locate every dependency on the repository lock.**

Run: `rg -n 'CORE_DIR/wari\.lock|core_dir/wari\.lock|/wari\.lock' tests tools install.sh wari`

Expected: each match is classified as a consuming-project path, a staged output path, or an obsolete core fixture copy. Replace only obsolete fixture copies with `write_format2_lock "$PROJECT/wari.lock"` or `write_format1_lock "$PROJECT/wari.lock" "$PROJECT/wari"`.

- [x] **Step 2: Make live installation select explicit fixture versions instead of reading the core lock.**

```bash
WARI_TEST_FRANKENPHP_VERSION="${WARI_TEST_FRANKENPHP_VERSION:-1.12.7}"
WARI_TEST_COMPOSER_VERSION="${WARI_TEST_COMPOSER_VERSION:-2.8.11}"

bash "$CORE_DIR/install.sh" --yes --local-source "$CORE_DIR" \
    --frankenphp "$WARI_TEST_FRANKENPHP_VERSION" \
    --composer "$WARI_TEST_COMPOSER_VERSION" \
    --linux-build "$WARI_LINUX_BUILD"
```

The live test must then read selected versions from the newly initialized project lock, run `./wari setup`, create or use its Laravel playground, and execute the existing Artisan/HTTP smoke assertions.

Replace the Composer hello-world project smoke with a Laravel project smoke while reusing the verified runtime:

```bash
LARAVEL_PROJECT="$LIVE_ROOT/laravel"
mkdir -p "$LARAVEL_PROJECT"
cp -R "$PROJECT/.wari" "$LARAVEL_PROJECT/.wari"
cp "$PROJECT/wari" "$LARAVEL_PROJECT/wari"
cp "$PROJECT/wari.lock" "$LARAVEL_PROJECT/wari.lock"
cp "$PROJECT/.gitignore" "$LARAVEL_PROJECT/.gitignore"
chmod 755 "$LARAVEL_PROJECT/wari"
(
    cd "$LARAVEL_PROJECT"
    ./wari create-project --yes laravel/laravel --no-interaction
    ./wari php artisan --version
    ./wari php artisan about --only=environment
)
```

- [x] **Step 3: Run all offline tests while the core lock still exists.**

Run:

```bash
for suite in \
    tests/test-lock.sh \
    tests/test-launcher.sh \
    tests/test-setup.sh \
    tests/test-update.sh \
    tests/test-initializer.sh \
    tests/test-installer.sh \
    tests/test-wrappers.sh \
    tests/test-create-project.sh \
    tests/test-service.sh; do
    bash "$suite" || exit 1
done
```

Expected: all suites pass using their own generated locks.

- [x] **Step 4: Delete the repository lock with the patch tool.**

Delete `wari.lock` only after Step 3 is green. Do not delete any project fixture lock created under a test temporary directory.

- [x] **Step 5: Prove core and tests work with no repository lock.**

Run: `test ! -e wari.lock && ! rg -n 'CORE_DIR/wari\.lock|core_dir/wari\.lock' tests tools install.sh wari`

Expected: exit status 0 and no search output.

Run the complete offline loop from Step 3 again.

Expected: all suites pass after physical deletion of the core lock.

Review checkpoint: inspect `git status --short` and `git diff -- tests wari.lock`; confirm the deletion is intentional and leave it unstaged.

---

### Task 8: Documentation, Release Guardrails, and Final Verification

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/test.yml` only if the live job needs the explicit version environment variables from Task 7
- Verify: `docs/superpowers/specs/2026-09-09-wari-project-only-version-lock-design.md`

**Interfaces:**
- Documents: project ownership, exact five-field lock, version repeatability, current-official-metadata integrity, format 1 migration, explicit setup, and no core lock.
- Produces: release gate requiring offline tests, local-source initialization, live Laravel setup, and immutable `v0.4.0` tag only after the tested source commit is pushed by the maintainer.

- [x] **Step 1: Replace checksum-lock language in README with the five-field model.**

Include this exact example:

```text
lock_version=2
wari_version=0.4.0
frankenphp_version=1.12.7
composer_version=2.8.11
linux_build=static
```

State plainly: `wari.lock` guarantees version selection, not byte-for-byte identity when an upstream release asset is rebuilt. Explain that setup obtains current checksums from official GitHub and Composer metadata, verifies downloads in the same run, and records those checksums only in ignored `.wari/manifest.json`.

- [x] **Step 2: Document migration and the developer workflow.**

Document that Wari 0.4 reads format 1, ignores its stored hashes during setup, `update` migrates it to format 2, and the 0.3.0 self-update handshake temporarily produces a valid format 1 lock. Remove instructions to regenerate or compare a core repository lock. Keep `./wari setup`, `./wari php artisan`, `./wari composer`, and service examples aligned with the refreshed CLI output.

- [x] **Step 3: Run documentation and static consistency checks.**

Run: `rg -n 'wari_sha256|composer_installer_sha384|frankenphp_.*_sha256|core wari.lock|launcher checksum' README.md docs/superpowers/specs/2026-09-09-wari-project-only-version-lock-design.md`

Expected: checksum key names appear only where the spec describes fields omitted from format 2 or legacy migration; README contains no core-lock regeneration instruction.

Run: `bash -n wari install.sh tools/generate-lock.sh tests/*.sh && git diff --check`

Expected: no syntax or whitespace errors.

- [x] **Step 4: Run the full offline verification matrix locally.**

```bash
for suite in \
    tests/test-lock.sh \
    tests/test-launcher.sh \
    tests/test-setup.sh \
    tests/test-update.sh \
    tests/test-initializer.sh \
    tests/test-installer.sh \
    tests/test-wrappers.sh \
    tests/test-create-project.sh \
    tests/test-service.sh; do
    bash "$suite" || exit 1
done
```

Expected: every suite reports zero failures.

- [x] **Step 5: Run the bounded live Laravel verification when network access is authorized.**

Run: `WARI_RUN_LIVE=1 WARI_LINUX_BUILD=static bash tests/test-live-install.sh`

Expected: local-source initialization writes format 2, current official artifacts verify, `.wari/manifest.json` records the in-run hashes, and the Laravel Artisan/HTTP smoke test passes.

- [x] **Step 6: Perform final repository review without staging or publishing.**

Run: `git status --short && git diff --stat && git diff --check`

Expected: `wari.lock` is deleted, intended implementation/spec/plan/README/test files are unstaged, unrelated user changes remain preserved, and whitespace validation is clean.

Review checkpoint: do not create the source commit or tag. Report the exact offline test count, whether the opt-in live test ran, and that the maintainer must push the tested commit before creating immutable `v0.4.0`.
