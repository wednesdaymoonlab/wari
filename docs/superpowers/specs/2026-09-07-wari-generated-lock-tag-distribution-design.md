# Wari Generated Lock and Git Tag Distribution Design

**Date:** 2026-09-07
**Status:** Approved
**Supersedes:** The initialization and update distribution model in
`2026-09-07-wari-project-local-team-runtime-design.md`

## Purpose

Make Wari installable immediately after its source is pushed and tagged,
without requiring a GitHub Release or a prebuilt `wari.lock` release asset.

The public initializer downloads one portable `wari` launcher from an exact
Git tag. That launcher resolves official upstream versions and checksums and
generates the project's `wari.lock`. This makes `wari.lock` analogous to a
dependency lock file: it is created during initialization, reviewed, and then
committed by the application team.

The resulting project workflow is:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
git add wari wari.lock .gitignore
git commit

# On every workstation and CI runner:
./wari setup
./wari composer install
```

The initializer does not download or create `.wari/`. Runtime installation
remains an explicit `./wari setup` operation.

## Decisions

- Wari distribution uses immutable semantic-version Git tags, not GitHub
  Release assets.
- `wari.lock` is generated in the target project during initialization.
- `./wari update` updates only the locked FrankenPHP and Composer dependencies.
- `./wari self-update <version>` is the only command that updates the tracked
  Wari launcher.
- Both initialization and dependency update support latest-stable resolution
  and exact version overrides.
- Initialization defaults Linux to `static` builds.
- Dependency update preserves the current `linux_build` unless the user passes
  an explicit override.
- Runtime-dependent commands never trigger setup implicitly.
- Windows remains outside the supported platform set.

## Goals

- Remove the requirement to create and upload a GitHub Release before Wari can
  initialize a project.
- Keep initialization reproducible and reviewable through a generated lock.
- Support macOS and Linux developers sharing the same tracked files.
- Keep launcher updates separate from runtime dependency updates.
- Use one canonical implementation for version resolution and lock generation.
- Preserve explicit setup, strict lock parsing, checksum validation, atomic
  runtime replacement, and rollback guarantees from the earlier design.
- Support local development before a Wari tag exists.

## Non-Goals

- Treating a generated lock as proof of artifact provenance.
- Providing cryptographic signing for Wari Git tags in this version.
- Updating the launcher as a side effect of `./wari update`.
- Automatically running `./wari setup` after a lock or launcher change.
- Allowing prerelease channels, arbitrary download URLs, version ranges, or
  floating dependency constraints.
- Making the installer itself a permanent project file.
- Creating Git commits, tags, pushes, or GitHub Releases for the user.

## Distribution Model

### Public initializer

The supported public entry point is:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
```

`install.sh` contains a default stable `WARI_VERSION`. It downloads the launcher
from the exact URL:

```text
https://raw.githubusercontent.com/wednesdaymoonlab/wari/v<WARI_VERSION>/wari
```

The initializer accepts an exact Wari override:

```bash
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh \
  | bash -s -- --wari 0.3.0
```

Only semantic versions of the form `MAJOR.MINOR.PATCH` are accepted. The tag
URL is constructed internally; no user-provided URL is accepted.

The `install.sh` fetched from `main` is therefore a stable bootstrap pointer,
while the installed launcher is pinned to an exact tag. Publishing a Wari
version requires pushing the source commit and its `vMAJOR.MINOR.PATCH` tag. A
GitHub Release is optional and has no effect on installation.

Repository administrators should protect version tags against deletion or
movement. HTTPS plus an exact tag prevents accidental drift only while the tag
remains immutable; this design does not claim stronger authenticity.

### Local development initializer

Maintainers can initialize from an untagged working copy:

```bash
bash ../../core/install.sh --local-source ../../core
```

`--local-source` must resolve to a real directory containing a regular
executable-capable `wari` file. The initializer copies that launcher into its
staging directory, validates its embedded version, and calculates its checksum.
It does not fetch a Wari launcher from GitHub. It still uses the network to
resolve or verify upstream FrankenPHP and Composer metadata unless tests inject
the existing controlled fixture transport.

`--local-source` and `--wari` are mutually exclusive.

## Generated Lock

The lock format remains `lock_version=1` and retains the existing fields:

```text
lock_version=1
wari_version=<exact version>
frankenphp_version=<exact version>
composer_version=<exact version>
linux_build=<static|gnu>
wari_sha256=<launcher SHA-256>
composer_installer_sha384=<installer SHA-384>
composer_sha256=<Composer PHAR SHA-256>
frankenphp_linux_x86_64_sha256=<SHA-256>
frankenphp_linux_arm64_sha256=<SHA-256>
frankenphp_macos_x86_64_sha256=<SHA-256>
frankenphp_macos_arm64_sha256=<SHA-256>
```

Generation writes fields in this canonical order with one trailing newline.
The existing strict parsing rules remain in force: unknown, duplicate, missing,
malformed, or unsupported fields are rejected and the file is never sourced or
evaluated as shell code.

The generated lock records checksums for all four supported OS/architecture
targets so the same committed lock works for a mixed macOS/Linux team. The
selected `linux_build` determines whether the two Linux entries describe static
or GNU/glibc assets; macOS entries are unchanged.

## Canonical Lock Generator

The tracked launcher owns a hidden, non-interactive lock-generation interface
used internally by the initializer and tests. Conceptually:

```text
wari --generate-lock <output> \
  [--frankenphp <exact-version>] \
  [--composer <exact-version>] \
  [--linux-build static|gnu]
```

This interface is not advertised as an end-user command. It must:

1. Validate its own embedded semantic version.
2. Calculate the SHA-256 of the exact launcher file being executed.
3. Resolve omitted dependency versions to latest stable releases.
4. Validate exact overrides and fetch metadata for those exact releases.
5. Fetch checksum data only from fixed official upstream hosts.
6. Build a complete canonical lock in a direct-child temporary file.
7. Parse and validate the completed candidate lock using the same production
   parser used by setup.
8. Atomically rename the candidate to the requested output.

The output must not be a symbolic link, directory, or path outside the expected
staging/project location. Failure leaves no partial lock at the destination.

`install.sh` does not duplicate upstream resolution logic. It stages the
launcher and invokes the staged launcher to create the staged `wari.lock`.
`./wari update` uses the same internal generator functions. This prevents the
initializer and launcher from gradually producing different lock files.

## Upstream Resolution and Verification

### FrankenPHP

For omitted versions, Wari resolves the latest stable release from the official
FrankenPHP GitHub Releases API. Drafts and prereleases are rejected. For an
exact override, it requests the exact `v<version>` release.

Wari selects the expected official asset names for:

- Linux x86-64;
- Linux ARM64;
- macOS x86-64; and
- macOS ARM64.

Linux names depend on `static` or `gnu`. Each selected asset must appear exactly
once, have the expected fixed GitHub download URL, and expose a valid SHA-256
digest in official release metadata. Missing or ambiguous assets fail lock
generation.

### Composer

For an omitted version, Wari resolves the first current stable Composer release
using Composer's official versions metadata. For an exact semantic-version
override, it derives the fixed official versioned checksum URL; a successful,
valid checksum response proves that exact release is available. Historical
Composer releases do not have to remain listed in the current-stable metadata.

Wari retrieves the exact PHAR's official `.sha256sum` from Composer's fixed
download host. It also retrieves the current official Composer installer
SHA-384 signature. It validates both metadata formats and records the installer
SHA-384 and PHAR SHA-256 in the lock. Lock generation does not download the
installer or PHAR itself; those artifacts are downloaded and verified only by
`./wari setup`.

During `./wari setup`, the installer checksum is checked before execution, and
the resulting PHAR is checked against the locked PHAR checksum as in the prior
design.

## Initialization Behavior

The initializer accepts:

```text
install.sh [--yes] [--migrate] [--wari VERSION]
           [--frankenphp VERSION] [--composer VERSION]
           [--linux-build static|gnu] [--local-source DIRECTORY]
```

Defaults are:

- embedded stable Wari version;
- latest stable FrankenPHP;
- latest stable Composer; and
- `linux_build=static`.

Examples:

```bash
# All defaults
bash install.sh --yes

# Reproducible exact runtime selection
bash install.sh --yes \
  --frankenphp 1.12.7 \
  --composer 2.8.11 \
  --linux-build gnu
```

After confirmation, initialization:

1. Performs existing destination and migration safety checks.
2. Creates a validated direct-child staging directory.
3. Downloads an exact tagged launcher, or copies the local source launcher.
4. Confirms the launcher's embedded version equals the selected Wari version.
5. Invokes the staged launcher to generate a complete staged lock.
6. Confirms the staged lock's Wari version and checksum match the launcher.
7. Publishes `wari` and `wari.lock` transactionally with existing rollback
   guarantees and executable permissions.
8. Adds the idempotent Wari block to `.gitignore`.
9. Reports that the user should review/commit tracked files and run
   `./wari setup` explicitly.

Initialization does not create `.wari/`, download runtime artifacts, execute
Composer, or alter application dependencies.

## Runtime Commands Before Setup

The prior explicit-setup behavior is unchanged. Commands including:

```bash
./wari php ...
./wari composer ...
./wari serve
./wari frankenphp ...
./wari create-project ...
```

must validate local runtime state before dispatch. If `.wari/` is absent,
incomplete, for another platform, or stale relative to `wari.lock`, they exit
non-zero without network access and print:

```text
Error: Wari runtime is not ready for this project.

Run:
  ./wari setup
```

Only `setup` performs runtime installation or repair.

## Dependency Update

The public interface is:

```text
./wari update [--yes]
  [--frankenphp VERSION]
  [--composer VERSION]
  [--linux-build static|gnu]
```

Behavior:

- With no dependency version flags, both dependencies resolve to latest stable.
- With one exact dependency flag, that dependency uses the exact version and the
  omitted dependency resolves to latest stable.
- `linux_build` is preserved from the current lock unless explicitly supplied.
- The Wari launcher is never downloaded or replaced.
- `wari_version` and `wari_sha256` must remain equal to the current launcher's
  version and checksum.
- `.wari/` is never changed.

Update generates a complete candidate lock rather than editing individual
lines in place. It shows the current and candidate dependency versions/build,
requires confirmation unless `--yes` is present, validates the candidate, and
atomically replaces only `wari.lock`. If every selected value and checksum is
unchanged, it reports that the lock is current and performs no replacement.

After a change it tells the user to inspect the lock diff and run:

```bash
./wari setup
```

Because the runtime manifest binds the complete lock digest, any lock change
makes an existing `.wari/` stale until setup succeeds. This is intentional.

## Launcher Self-Update

The public interface requires an exact target version:

```text
./wari self-update <MAJOR.MINOR.PATCH> [--yes]
```

There is no implicit latest channel in this version. Self-update:

1. Strictly validates the current launcher and lock.
2. Refuses to overwrite a launcher whose checksum differs from the current
   `wari_sha256`.
3. Downloads the candidate launcher from its exact Git tag into a validated
   direct-child staging directory.
4. Validates the candidate's embedded version against the requested version.
5. Invokes the candidate's lock generator using the current exact FrankenPHP
   version, Composer version, and Linux build.
6. Validates the candidate launcher/lock pair.
7. Shows the Wari version comparison and requires confirmation unless `--yes`
   is present.
8. Replaces `wari` and `wari.lock` transactionally with backups and ordered
   renames, restoring both on any failure.

This preserves the dependency selections but refreshes their official checksum
metadata. Normally unchanged upstream artifacts yield an identical dependency
portion. A checksum change for an already-pinned upstream version is visible in
the Git diff and must not be hidden.

Self-update leaves `.wari/` untouched. The complete lock digest changes, so the
runtime becomes stale and the user must review the diff and run `./wari setup`.

Self-update cannot guarantee a literal atomic swap of two independent files.
It uses staged files, exact backups, ordered publication, signal-safe cleanup,
and rollback to provide transaction-like behavior. If rollback itself cannot
complete, it emits explicit recovery paths and does not delete the backups.

## Validation Interfaces

The launcher must expose a machine-readable, side-effect-free way for trusted
bootstrap code to read its embedded version, such as:

```text
wari --version-value
```

It should also centralize launcher/lock pair validation so initialization,
setup, update, and self-update apply the same rules. Hidden interfaces:

- produce no localized or decorative output on success;
- never access runtime state unless their contract requires it;
- return non-zero with a precise diagnostic on malformed input; and
- remain covered by compatibility tests because the public initializer depends
  on them across Wari versions.

## Security Model

### Wari launcher

The launcher is fetched over HTTPS from an exact semantic-version Git tag. The
initializer validates the embedded version, computes the received file's
SHA-256, and writes that digest into the generated lock. Subsequent operations
detect local launcher modification by comparing against the committed lock.

Unlike the former GitHub Release model, no separately published digest
authenticates the first launcher download. The initial trust boundary is
therefore GitHub HTTPS, repository access control, and immutability of the
selected tag. The generated digest provides change detection and Git-review
visibility after installation; it does not retroactively prove who authored
the initially downloaded bytes.

### Upstream artifacts

Dependency URLs are derived only from strict versions and fixed official hosts.
Checksums come from official upstream metadata, are validated during lock
generation, committed for review, and checked again against downloaded bytes
during setup. Redirect destinations remain constrained by the existing secure
download policy.

### Shell and filesystem safety

- Lock files and remote metadata are parsed as data, never sourced.
- Versions, digests, asset names, paths, and cardinality are strictly validated.
- Temporary and backup paths are exact, validated direct children of the
  project root.
- Existing symlinks or non-regular tracked destinations are rejected.
- Cleanup never relies on broad globs or unvalidated variables.
- Signals and partial publication retain rollback capability.

## Error Handling

Errors must distinguish at least:

- the requested Wari tag does not exist;
- the candidate launcher version does not match the tag;
- stable dependency metadata is missing or malformed;
- an exact dependency version does not exist or is not stable;
- an expected platform asset is missing, duplicated, or has no valid digest;
- Composer checksum metadata is missing or invalid;
- the local launcher has uncommitted modifications relative to its lock;
- the lock schema is unsupported;
- a destination or temporary path is unsafe; and
- publication or rollback failed.

Network operations retain bounded retries for transport failures. HTTP errors
that prove a requested exact version does not exist should fail with a useful
message rather than being described as a missing GitHub Release asset.

## Test Strategy

Implementation follows test-driven development. Offline tests must cover:

- initializer exact-tag URL construction and absence of GitHub Release API use;
- generated lock creation with latest-stable fixture metadata;
- exact dependency overrides and mixed exact/latest behavior;
- default `static` initialization and explicit `gnu` initialization;
- update preservation and override of `linux_build`;
- `./wari update` changing only the lock;
- `./wari self-update` changing launcher identity while preserving exact
  dependency versions;
- missing/non-semantic tags and embedded-version mismatches;
- strict metadata, digest, URL, path, and cardinality rejection;
- atomic publication, rollback, signals, and cleanup;
- local-source initialization before a tag exists;
- commands before setup returning the explicit setup message with no network;
- shell syntax and the full existing setup/wrapper/create-project regression
  suite.

The live integration test initializes through `--local-source` so it can verify
unreleased main-branch work. It then performs real upstream resolution, setup,
version checks, Composer use, create-project, and HTTP smoke checks. An optional
tag-distribution smoke test may be run only after the matching tag is pushed;
the normal CI suite must not require a GitHub Release.

## Documentation and Release Workflow

README and contributor documentation must explain:

- `wari.lock` is generated during initialization and should be committed;
- `.wari/` is generated by explicit setup and must remain ignored;
- mixed-platform collaborators share the launcher and lock, not the runtime;
- dependency updates use `./wari update`;
- launcher updates use exact-version `./wari self-update`;
- maintainers publish by pushing a protected version tag;
- GitHub Releases are optional; and
- local development uses `--local-source`.

For Wari version `0.2.1`, the maintainer flow after merging/pushing the final
source is conceptually:

```bash
git tag v0.2.1
git push origin v0.2.1
```

The tool and its automation do not run these commands. Version consistency and
tests must pass before the maintainer creates the tag.

## Compatibility with the Prior Design

Everything not changed here remains governed by the approved project-local
team runtime design, including repository layout, `.gitignore`, strict lock
parsing, manifest binding, setup concurrency, platform detection, glibc checks,
runtime staging and rollback, Composer execution, wrappers, `serve`, and
`create-project`.

The following prior behavior is explicitly removed:

- initialization downloading `wari` and `wari.lock` as GitHub Release assets;
- `./wari update` discovering or installing a newer Wari release; and
- requiring a GitHub Release before a pushed Wari version can be consumed.
