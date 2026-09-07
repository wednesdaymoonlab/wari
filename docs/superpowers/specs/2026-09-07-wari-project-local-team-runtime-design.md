# Wari Project-Local Team Runtime Design

> **Superseded in part:** The initialization and tracked-file update model is
> replaced by
> [Wari Generated Lock and Git Tag Distribution Design](2026-09-07-wari-generated-lock-tag-distribution-design.md).
> The runtime, explicit setup, platform, manifest, and rollback guarantees in
> this document remain active.

**Date:** 2026-09-07

## Purpose

Make Wari safe and predictable when it lives inside an application repository
used by developers on different operating systems and CPU architectures.

The repository will track a portable `wari` launcher and a `wari.lock` file.
Each workstation and CI runner will create its own ignored `.wari/` runtime by
running an explicit setup command:

```bash
git clone <repository>
cd <project>
./wari setup
./wari composer install
```

Running a runtime-dependent command before setup must fail with instructions;
it must never initiate an implicit download.

## Background

The current installer publishes `.wari/` and a root `wari` dispatcher together.
The root dispatcher is linked to the generated dispatcher inside `.wari/`.
That layout is relocatable on one machine, but the public command is still an
installation artifact. Committing the current output would also commit a
platform-specific FrankenPHP binary. A macOS developer and a Linux developer
could not safely share that runtime through Git.

The new boundary is:

- Git owns the portable launcher, the lock file, and the ignore rules.
- The local machine owns the downloaded runtime and transient setup state.
- The launcher validates that the local state matches both the current machine
  and the committed lock before dispatching a command.

## Goals

- Support one repository used on supported macOS and Linux combinations.
- Require an explicit `./wari setup` before any runtime download or repair.
- Give every team member the exact Wari, FrankenPHP, and Composer versions
  selected by the repository.
- Keep all native binaries and generated wrappers out of Git.
- Make setup idempotent, concurrency-safe, and rollback-safe.
- Make version updates reviewable Git changes rather than hidden machine state.
- Preserve the existing project-local execution behavior of PHP, Composer,
  FrankenPHP, `serve`, and `create-project`.
- Remain usable without a globally installed PHP, Composer, Docker, Homebrew,
  or Linux package manager.

## Non-Goals

- Committing native binaries for every platform.
- Automatically downloading a runtime when `php`, `composer`, `serve`, or
  `frankenphp` is invoked.
- Automatically running `composer install` during Wari setup.
- Automatically committing or pushing an update.
- Sharing `.wari/` between workstations or CI jobs as a portable artifact.
- Supporting Windows, Git Bash, or native Windows PowerShell in this version.
- Providing a global Wari installation.
- Proving artifact provenance solely from a checksum.

## Repository and Local Layout

The application repository tracks:

```text
project/
├── wari
├── wari.lock
├── .gitignore
└── application files
```

The workstation creates and ignores:

```text
.wari/
.wari-install.*
.wari-backup.*
.wari-update.*
.wari-setup.lock
```

The managed `.gitignore` block is:

```gitignore
# Wari local runtime
/.wari/
/.wari-install.*
/.wari-backup.*
/.wari-update.*
/.wari-setup.lock
```

The initializer appends the block when it is absent and leaves unrelated
`.gitignore` content untouched. Repeated initialization must not duplicate the
block. The launcher itself is a regular executable file tracked with Git's
executable bit; it is not a hard link or symbolic link into `.wari/`.

## Tracked Launcher

`wari` is a portable Bash launcher shared by every supported platform. It owns
only project-level orchestration:

- locating the physical project root relative to itself;
- strictly parsing `wari.lock`;
- detecting the operating system and CPU architecture;
- implementing `setup`, `update`, `help`, and `--version` without a runtime;
- validating `.wari/manifest.json` before runtime-dependent commands; and
- dispatching valid commands to wrappers inside `.wari/`.

These commands work before setup:

```text
./wari setup [--yes]
./wari update [--yes]
./wari help
./wari --help
./wari --version
```

These commands require a valid local runtime:

```text
./wari php ...
./wari composer ...
./wari serve
./wari frankenphp ...
./wari create-project ...
```

The launcher never performs setup as a side effect of dispatch. If a runtime is
missing, incomplete, built for another platform, or inconsistent with the lock,
the command exits non-zero and prints:

```text
Error: Wari runtime is not ready for this project.

Run:
  ./wari setup
```

Where useful, the error also displays the installed and required platform and
versions. It must not perform a network request before returning this error.

## Lock File

`wari.lock` is a deterministic, line-oriented key/value document. The first
format uses the following conceptual fields:

```text
lock_version=1
wari_version=0.2.1
frankenphp_version=1.12.7
composer_version=2.8.11
linux_build=static
wari_sha256=<64 lowercase hexadecimal characters>
composer_installer_sha384=<96 lowercase hexadecimal characters>
composer_sha256=<64 lowercase hexadecimal characters>
frankenphp_linux_x86_64_sha256=<64 lowercase hexadecimal characters>
frankenphp_linux_arm64_sha256=<64 lowercase hexadecimal characters>
frankenphp_macos_x86_64_sha256=<64 lowercase hexadecimal characters>
frankenphp_macos_arm64_sha256=<64 lowercase hexadecimal characters>
```

When `linux_build=gnu`, the two Linux checksums refer to the GNU/glibc assets;
the macOS checksums remain unchanged. `static` is the default because it is the
most portable Linux choice. The choice is repository-wide for Linux machines;
there is no untracked per-developer override in this design.

The parser must:

- never evaluate or `source` the file;
- accept only known keys exactly once;
- reject missing, duplicate, or unknown keys;
- reject whitespace, control characters, shell syntax, and invalid versions;
- validate SHA-256 checksums as exactly 64 lowercase hexadecimal characters;
- validate the Composer installer SHA-384 as exactly 96 lowercase hexadecimal
  characters; and
- reject unsupported `lock_version` values with an upgrade instruction.

Artifact URLs are derived from validated versions and fixed official host
templates. They are not arbitrary lock-file inputs. This prevents a reviewed
lock file from silently redirecting setup to another host.

The checksums make the selected bytes reviewable and reproducible. They detect
corruption or changed upstream bytes but do not, by themselves, prove build
provenance.

## Runtime Manifest and Validation

`.wari/manifest.json` remains local and records at least:

- Wari and lock-format versions;
- an unambiguous digest of the complete `wari.lock` content;
- normalized operating system and architecture;
- selected Linux build when applicable;
- exact PHP, FrankenPHP, and Composer versions;
- artifact names, canonical URLs, and verified checksums;
- installation time; and
- truthful verification and provenance flags.

Before dispatch, the launcher verifies:

- `.wari/` is a real directory and not a symbolic link;
- the manifest is present, structurally valid, and owned by a supported Wari
  layout version;
- the manifest lock digest equals the current `wari.lock` digest;
- the manifest platform equals the current normalized platform;
- required wrappers are regular executable files;
- the FrankenPHP binary is executable;
- `composer.phar` is a regular file; and
- lightweight version checks agree with the manifest.

Setup performs full artifact checksum verification. Normal command dispatch
does not hash large artifacts on every invocation; manifest/lock matching and
lightweight smoke checks keep normal commands fast. A future explicit verify
command may provide full revalidation, but it is outside this design.

## `setup` Command

`./wari setup` manages only the local Wari runtime. It never installs the
application's Composer dependencies.

The command proceeds as follows:

1. Resolve the project root and validate `wari` and `wari.lock`.
2. Acquire an atomic setup lock using `mkdir` on `.wari-setup.lock`.
3. Detect the current operating system and architecture.
4. If the existing runtime passes validation, report that it is ready and exit
   zero without a network request.
5. If replacement is required, create a direct-child staging directory named
   `.wari-install.<random>`.
6. Download only the artifact selected for the current platform plus the exact
   Composer version in the lock.
7. Verify all artifacts, generate wrappers and the manifest, and run staged
   smoke checks.
8. Move a recognized old runtime to `.wari-backup.<random>`, publish the staged
   runtime as `.wari/`, and run public smoke checks through the tracked launcher.
9. On success, delete the recognized backup and release the setup lock.
10. On failure after replacement begins, restore the old runtime and return
    non-zero.

If no runtime exists, setup installs it. If an existing runtime already matches,
setup is idempotent. If a recognized runtime has a stale lock, another platform,
or an incomplete owned layout, setup replaces it.

If `.wari/` exists but Wari cannot prove ownership from a valid marker and
manifest, setup refuses to move or delete it:

```text
Error: .wari/ exists but is not a recognized Wari runtime.
Move or remove it manually, then run:
  ./wari setup
```

All staging, backup, lock, and cleanup paths must be exact validated direct
children of the project root. Cleanup must not rely on globs or unresolved
environment variables. Signal handlers cover normal errors plus `INT` and
`TERM`. A stale setup lock includes enough diagnostic information for a user to
inspect it; Wari does not break an apparently active lock automatically.

`--yes` suppresses only Wari's setup confirmation. It is required for a setup
that needs downloads in a non-interactive environment. An already-valid setup
may return success without a terminal or `--yes` because it makes no change.

## Composer Installation

Wari fetches the official Composer installer, verifies it against the
`composer_installer_sha384` committed in the lock before execution, and
provides the staged FrankenPHP executable as PHP. Pinning this digest avoids
trusting a newly fetched installer and a newly fetched checksum as an
unreviewed pair during every setup. `./wari update` refreshes the digest when a
new Wari release intentionally adopts a newer installer. Wari passes the exact
locked Composer release with `--version=<composer_version>`, along with the
existing installation directory and filename options.

The official installer verifies the downloaded Composer PHAR using Composer's
release signature. After installation, Wari additionally verifies the PHAR's
SHA-256 digest against `composer_sha256` and checks the reported Composer
version. Any mismatch fails staged setup and leaves the published runtime
unchanged.

## `update` Command

`./wari update` updates tracked project tooling, not local runtime state. Its
interface is:

```text
./wari update [--yes]
```

The first version updates to the latest stable Wari release. Selecting arbitrary
dependency combinations or prerelease channels is outside this design.

The command:

1. Validates the current launcher and lock, including the current
   `wari_sha256`, and refuses to overwrite a locally modified launcher.
2. Retrieves the latest stable Wari release metadata from the fixed official
   repository.
3. Shows a table comparing current and proposed Wari, FrankenPHP, and Composer
   versions.
4. Requires confirmation unless `--yes` is supplied.
5. Downloads the candidate launcher and complete lock into a validated
   `.wari-update.<random>` staging directory.
6. Verifies the candidate launcher checksum, lock schema, artifact checksum
   fields, and agreement between `wari_version` and the launcher's embedded
   version.
7. Replaces `wari` and `wari.lock` using backups and ordered renames, preserving
   executable permissions.
8. Leaves `.wari/` untouched and instructs the user to inspect the Git diff,
   run setup, test the project, and commit the two tracked files.

POSIX filesystems cannot atomically replace two independent tracked files as
one operation. Update is therefore transaction-like rather than literally
atomic: traps perform best-effort rollback, and every launcher invocation
detects a launcher/lock version or checksum mismatch. If power loss interrupts
the two-file publication, Wari reports the inconsistency and instructs the user
to rerun update or restore the tracked files with Git; it never silently uses a
mismatched pair.

`update` does not run `setup`, `composer install`, tests, `git add`, `git commit`,
or `git push`. CI should not run `update`; CI must consume the versions already
reviewed and committed in `wari.lock`.

## Initializing a Repository

The remotely delivered `install.sh` becomes a project initializer. For a normal
initialization it:

- refuses unsafe collisions with an existing unrecognized `wari` or
  `wari.lock`;
- stages and verifies the tracked `wari` launcher and `wari.lock`;
- creates or updates the managed Wari block in `.gitignore` without changing
  unrelated lines;
- preserves executable mode on `wari`;
- does not create `.wari/` or download FrankenPHP or Composer; and
- prints `./wari setup` as the required next step.

The initializer output identifies all tracked files it created or changed so
the user can review and commit them.

The new-project flow is:

```bash
mkdir php-app
cd php-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
./wari create-project vendor/project
```

The existing one-command installer behavior is intentionally replaced by this
explicit initialization/setup split.

## Legacy Layout Migration

An existing installation may contain a generated root `wari` linked to
`.wari/wari`. The initializer must not mistake that generated dispatcher for a
tracked launcher or overwrite it by default.

A focused `install.sh --migrate` path converts the legacy layout only after
it proves all of the following:

- `.wari/` has a valid legacy Wari manifest;
- `.wari/wari` is the recognized legacy dispatcher; and
- the root `wari` refers to the same file as `.wari/wari`.

Migration stages the new launcher and lock, replaces only the root dispatcher,
adds the ignore block, and leaves the legacy `.wari/` untouched. The new
launcher then reports the lock/layout mismatch and requires `./wari setup` to
replace the runtime. If ownership cannot be proved, migration refuses the
operation and prints manual recovery instructions.

Migration support and its tests are required before the new initializer replaces
the current installation flow. Documentation for the new layout must not tell
users to commit the old generated dispatcher or runtime.

## `create-project` Integration

The strict `create-project` preflight changes because the bootstrap root now
contains four Wari-managed entries:

```text
.wari/
wari
wari.lock
.gitignore
```

For this special new-project flow, `.gitignore` must contain exactly the
initializer-produced Wari block; custom root content still fails strict
preflight. `wari`, `wari.lock`, and `.wari/` retain their existing ownership and
symlink-safety checks.

The staged Composer project must not contain `wari`, `wari.lock`, or `.wari/`.
A staged `.gitignore` is allowed. Before publication, Wari creates the final
`.gitignore` in staging by preserving the package's content and appending the
managed Wari block if absent. It then replaces the bootstrap-only root
`.gitignore` as part of the ownership-tracked publication transaction. If the
package has no `.gitignore`, Wari retains the bootstrap file.

Rollback restores the bootstrap `.gitignore` and removes only entries published
by the current invocation. Concurrent or unrecognized root changes remain
protected by the existing no-overwrite rules.

After success, the tracked launcher and lock are preserved, the generated
runtime remains local, and the final `.gitignore` is ready to commit with the
new application.

## Team Workflow

After clone:

```bash
./wari setup
./wari composer install
```

To prepare a reviewed update:

```bash
./wari update
git diff -- wari wari.lock
./wari setup
./wari composer install
# Run the project's tests.
git add wari wari.lock
git commit -m "Update Wari runtime"
```

After another developer pulls that commit, runtime commands report the lock
mismatch until that developer explicitly runs `./wari setup`. Switching between
branches with different locks has the same behavior.

CI uses:

```bash
./wari setup --yes
./wari composer install --no-interaction
# Run the project's tests.
```

CI may cache `.wari/` using a cache key derived from the operating system,
architecture, Linux build, and full `wari.lock` digest. Cache restoration is an
optimization only; the launcher validates restored content normally.

If an archive or filesystem loses executable mode, documentation provides
`bash ./wari setup` as the recovery entry point. Normal Git clones are expected
to preserve the tracked executable bit.

## Error and Exit Behavior

- Successful help, version display, valid no-op setup, completed setup, and
  completed update return zero.
- Invalid commands, lock data, layouts, checksums, platforms, or arguments
  return non-zero.
- A runtime-dependent command with no valid runtime returns non-zero and shows
  `./wari setup`; it performs no network or filesystem mutation.
- Declining an interactive setup or update confirmation returns success without
  mutation.
- Download failures return non-zero after bounded retries and cleanup.
- Composer installer failures return non-zero and never publish staged content.
- Cleanup failures are reported and never cause Wari to broaden a deletion
  target.
- Unsupported platforms fail before downloading an artifact.

User-facing errors must distinguish at least missing runtime, stale lock,
platform mismatch, incomplete recognized runtime, unrecognized `.wari/`, active
setup, checksum failure, and unsupported platform.

## Security Model

- The tracked launcher is executable code and enters a project through explicit
  initialization or Git review.
- Lock data is parsed as data, never shell code.
- Downloads use HTTPS and fixed official hosts.
- FrankenPHP is checked against the exact per-platform SHA-256 committed in the
  lock.
- The Composer installer is checked against the reviewed SHA-384 committed in
  the lock; Composer verifies its PHAR signature; Wari also checks the exact
  locked PHAR SHA-256 and reported version.
- Update candidates are staged and verified before tracked files are replaced.
- Existing user paths are never moved or removed unless Wari can prove their
  ownership and exact safe location.
- The manifest states whether provenance was verified; checksum verification
  alone must not be described as provenance verification.

Optional GitHub attestation verification may be documented when `gh` is already
available, but `gh` is not installed or required automatically.

## Test Strategy

Offline tests use fake platform detection, downloads, artifacts, Composer, and
temporary project roots. They cover:

- strict lock parsing, including missing, duplicate, unknown, malicious, and
  malformed values;
- launcher operation without a runtime;
- no network attempt from runtime-dependent commands before setup;
- clear setup guidance for every invalid runtime state;
- initial setup on macOS/Linux and x86_64/ARM64 mappings;
- Linux static and GNU asset selection;
- exact Composer version arguments and post-install version verification;
- every artifact checksum mismatch;
- idempotent setup with no download;
- recognized stale, cross-platform, and incomplete runtime replacement;
- refusal to replace an unrecognized `.wari/`;
- setup lock contention and stale-lock diagnostics;
- setup failure and signal rollback before and after publication;
- preservation of a valid old runtime after failed setup;
- updater comparison, confirmation, `--yes`, staging, and validation;
- updater refusal when the tracked launcher has local modifications;
- updater rollback and detectable two-file interruption states;
- initializer collision handling, executable mode, and idempotent ignore block;
- recognized legacy migration and refusal of ambiguous legacy layouts;
- `create-project` preflight with all four managed entries;
- safe merging and rollback of package `.gitignore` content;
- preservation of `wari`, `wari.lock`, and `.wari/` during project creation;
- paths containing spaces and shell metacharacters;
- cleanup path safety and absence of abandoned normal staging paths; and
- all existing installer, wrapper, and `create-project` regression behavior
  that remains applicable to the new architecture.

Live verification covers at least macOS and Linux and must:

- initialize a disposable repository;
- run explicit setup with real official downloads;
- confirm the selected native artifact and exact Composer version;
- execute PHP and Composer through the tracked launcher;
- rerun setup and confirm the no-op path;
- exercise a lock change followed by explicit replacement; and
- exercise a small framework-neutral `create-project` flow.

CI matrix entries should distinguish operating system and architecture where
runners are available. Platform-selection unit tests remain mandatory even when
a hosted runner is unavailable for one architecture.

## Documentation Changes

The README will explain:

- which files are committed and ignored;
- initialization versus explicit local setup;
- clone, update, branch-switch, and CI workflows;
- the absence of implicit downloads;
- recovery for missing executable mode and unrecognized local state;
- the revised four-entry `create-project` bootstrap root; and
- the supported platform matrix and Linux build choice.

Compatibility guides continue to use framework-specific examples, but they all
invoke `./wari setup` before Composer or PHP commands.

## Success Criteria

The design is complete when:

- a single Git commit containing `wari`, `wari.lock`, and ignore rules works for
  supported macOS and Linux developers;
- no platform-specific `.wari/` content needs to enter Git;
- commands never download implicitly;
- setup creates or replaces local state safely and reproducibly;
- pull and branch-switch mismatches produce an actionable setup message;
- updates are visible, reviewable tracked-file changes;
- failed setup/update operations preserve valid prior state whenever possible;
- `create-project` preserves the new tracked files and final ignore rules; and
- offline regression tests and supported live platform tests pass.
