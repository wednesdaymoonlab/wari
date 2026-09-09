# Wari Project-Only Version Lock Design

**Date:** 2026-09-09
**Status:** Approved
**Target:** Wari 0.4.0

## Summary

`wari.lock` becomes a project-owned version-selection file. It records which
Wari, FrankenPHP, Composer, and Linux build variants a PHP project uses, but it
does not pin upstream artifact bytes. The Wari source repository no longer
tracks its own `wari.lock`.

During installation, Wari retrieves current integrity metadata from official
upstream sources and verifies every downloaded artifact before publishing the
local runtime. This preserves fail-closed download verification while allowing
an upstream project to rebuild an asset under the same released version.

## Goals

- Make a fresh clone install the versions selected by the project's
  `wari.lock`.
- Avoid permanent setup failures when an official upstream release asset is
  rebuilt without changing its version.
- Keep integrity verification for every network download.
- Remove `wari.lock` from the Wari core repository and release artifacts.
- Preserve explicit setup, atomic publication, rollback, signal safety, and
  the existing official-source allowlists.
- Provide a clear migration path from lock format 1.

## Non-goals

- Guarantee byte-for-byte identical upstream binaries for a given version.
- Cache or mirror FrankenPHP or Composer artifacts.
- Add an optional strict-checksum mode.
- Mutate a tracked project lock as a side effect of `./wari setup`.
- Change the `.wari/` runtime layout or make it project-tracked.

## Repository Ownership

The Wari source repository contains:

```text
wari
install.sh
tools/
tests/
docs/
```

It does not contain `wari.lock`.

A project initialized with Wari contains:

```text
wari
wari.lock
.gitignore
.wari/          # ignored, machine-local runtime
```

Both `wari` and `wari.lock` remain tracked project files. The lock belongs to
the consuming PHP project, not to the Wari source distribution.

## Lock Format 2

New project locks contain exactly these keys in this order:

```text
lock_version=2
wari_version=0.4.0
frankenphp_version=1.12.7
composer_version=2.8.11
linux_build=static
```

The existing lexical rules remain: one `key=value` record per line, no blank
lines, no duplicate or unknown keys, no whitespace or control characters in
values, strict semantic versions, and `linux_build` limited to `static` or
`gnu`.

Format 2 deliberately omits:

- `wari_sha256`
- `composer_installer_sha384`
- `composer_sha256`
- all platform-specific FrankenPHP SHA-256 values

`wari_version` binds the project lock to the launcher by version rather than
by launcher bytes. Wari compares `wari_version` with the launcher's internal
version before commands that operate on project state.

## Core CLI Without a Lock

The standalone launcher must support these commands when no adjacent
`wari.lock` exists:

- `./wari help`, `./wari --help`, and `./wari -h`
- `./wari --version`
- internal maintainer and initializer operations that generate or validate a
  supplied lock path

Project operations such as `setup`, `update`, `self-update`, `php`, `composer`,
`create-project`, `serve`, `frankenphp`, and service generation still require
an adjacent valid project lock. A missing lock produces a focused error that
explains that Wari must be initialized in a PHP project.

## Initialization Flow

`install.sh` remains the public project initializer:

1. Select an exact Wari version, defaulting to the initializer's version.
2. Download the launcher from the corresponding immutable Wari Git tag, or
   use the explicit local source during development.
3. Resolve the requested or latest stable FrankenPHP and Composer versions
   from official metadata.
4. Generate a format 2 lock containing only version selections and the Linux
   build variant.
5. Verify that the downloaded launcher's internal version equals
   `wari_version` in the generated lock.
6. Atomically publish `wari`, `wari.lock`, and the managed `.gitignore` block.
7. Leave runtime installation explicit through `./wari setup`.

The initializer never downloads runtime artifacts and does not consume a
`wari.lock` from the Wari Git tag.

## Setup and Live Integrity Verification

`./wari setup` first checks whether the existing `.wari/` runtime matches the
project lock and current platform. A matching runtime returns without network
access.

When installation or replacement is required:

1. Parse the exact versions and Linux build from the project lock.
2. Resolve the platform-specific FrankenPHP asset from the official GitHub
   release metadata for `frankenphp_version`.
3. Require one unique asset with the expected official release URL and a valid
   GitHub-provided SHA-256 digest.
4. Download the asset through the existing HTTPS host and redirect allowlists.
5. Verify the downloaded bytes against the digest retrieved in this setup run.
6. Retrieve the Composer installer signature from Composer's official HTTPS
   endpoint and verify the installer before execution.
7. Retrieve the official checksum for the exact locked Composer version and
   verify the downloaded PHAR.
8. Probe the installed PHP, FrankenPHP, and Composer binaries and require their
   reported versions to match the project lock.
9. Write the verified runtime manifest and atomically publish `.wari/`.

Checksums used during setup are recorded in the ignored runtime manifest for
diagnostics, but never in the project lock. Setup never rewrites
`wari.lock`.

This model guarantees version repeatability and verification against current
official metadata. It does not guarantee that two installations made at
different times receive identical bytes when an upstream release is mutable.

## Update Behavior

`./wari update` resolves the requested or latest stable FrankenPHP and Composer
versions and writes a format 2 candidate lock. It preserves `wari_version` and
the current Linux build unless explicitly overridden.

If the selected versions and build are unchanged, the command reports that the
lock is current and does not rewrite it. Changes remain confirmation-gated and
are published atomically. Updating a format 1 lock always produces format 2,
even when all selected versions remain the same.

`update` does not download runtime artifacts. The user reviews the tracked lock
change and runs `./wari setup` explicitly.

## Self-update Behavior

`./wari self-update VERSION` when initiated by Wari 0.4.0 or newer:

1. Downloads the launcher from the exact requested Wari Git tag.
2. Requires the launcher's internal version to equal `VERSION`.
3. Builds a format 2 lock with the new `wari_version` while preserving the
   locked FrankenPHP version, Composer version, and Linux build.
4. Atomically publishes the launcher and lock together, with rollback across
   partial publication or post-publication validation failure.
5. Leaves `.wari/` untouched and instructs the user to run `./wari setup`.

No launcher checksum is stored. The exact Wari tag plus internal version check
is the project-level identity contract.

### Upgrade handshake from Wari 0.3.0

Wari 0.3.0 validates the candidate lock with its format 1-only parser before
publishing a self-update. That released code cannot publish a format 2 lock.
The Wari 0.4.0 hidden lock generator therefore supports an internal
`--lock-version 1|2` option and defaults to format 1 when the option is absent:

- Wari 0.3.0 calls the 0.4.0 candidate without `--lock-version`, receives a
  format 1 candidate, validates it, and completes the self-update.
- Wari 0.4.0 accepts that valid legacy lock and ignores its stored artifact
  checksums during setup.
- The next `./wari update` naturally rewrites the project lock as format 2.
- Wari 0.4.0's initializer, dependency update, self-update, and maintainer
  tooling explicitly request `--lock-version 2`.

This handshake lets existing projects upgrade without modifying the released
0.3.0 launcher, without automatic tracked-file mutation during setup, and
without requiring users to run a dedicated migration command. New projects
initialized by the 0.4.0 initializer receive format 2 immediately.

## Format 1 Migration

Wari 0.4.0 accepts both lock formats while reading:

- Format 1 retains its existing required checksum fields and strict parser so
  malformed legacy locks are still rejected.
- Dependency and launcher checksums read from format 1 are not used to install
  artifacts under the new trust model.
- `setup` may consume a valid format 1 lock but never mutates it.
- `update` and self-updates initiated by Wari 0.4.0 or newer emit format 2.
- The compatibility handshake for a self-update initiated by Wari 0.3.0 emits
  format 1, which Wari 0.4.0 can consume until the next dependency update.
- The initializer always emits format 2.

This compatibility is transitional. Removal of format 1 parsing requires a
future major compatibility decision and is outside Wari 0.4.0.

## Runtime Manifest

The ignored `.wari/manifest.json` continues to record:

- layout version
- digest of the complete project lock
- Wari, PHP, FrankenPHP, and Composer versions
- operating system, architecture, and Linux build
- selected asset name and official URL
- checksums actually verified during that setup run
- installation timestamp and verification flags

The manifest binds an installed runtime to the project lock and machine. A
format migration or version change makes the runtime stale and requires
explicit setup. Manifest checksums are diagnostic records, not inputs to later
downloads.

## Failure Handling

- Missing, malformed, or unsupported locks fail before network access.
- Missing or ambiguous official metadata fails before artifact download.
- A downloaded artifact that differs from metadata fetched in the same run is
  rejected and never published.
- A binary whose reported version differs from the project lock is rejected.
- Existing recognized runtimes remain recoverable through the current staging,
  backup, signal, and rollback paths.
- Failures never rewrite the project lock or replace a valid existing runtime.

## Testing Strategy

Offline tests use generated format 1 and format 2 fixture locks rather than a
repository-level lock. Coverage must include:

- strict format 2 parsing and rejection of checksum keys in format 2
- backward-compatible strict format 1 parsing
- core help and version commands without an adjacent lock
- project commands rejecting a missing lock before network access
- initializer output containing exactly the five format 2 keys
- setup resolving live fixture metadata for locked versions
- setup accepting a changed official digest for the same locked version
- setup rejecting a download that differs from metadata fetched in that run
- setup leaving the tracked lock byte-for-byte unchanged
- idempotent setup avoiding metadata and artifact network calls
- update and self-update migration from format 1 to format 2
- successful 0.3.0-to-0.4.0 self-update through the format 1 compatibility
  handshake
- atomic publication, rollback, signal safety, and generated-service behavior
- full Linux and macOS asset-selection coverage

The live test downloads current official artifacts into bounded temporary
storage and verifies a Laravel application smoke test. It remains opt-in.

## Documentation and Release

README documentation will define `wari.lock` as a version lock rather than an
artifact-integrity lock and explicitly state the loss of byte-for-byte
reproducibility. Release instructions will no longer compare a tagged
repository lock because no core lock exists.

Wari 0.4.0 must not be published until:

- the core `wari.lock` is removed
- all offline tests pass without it
- local-source initialization creates a valid format 2 project lock
- a fresh Laravel playground setup succeeds
- the Wari source commit is pushed
- immutable tag `v0.4.0` points to that tested commit
