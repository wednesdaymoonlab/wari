# Wari `create-project` Command Design

**Date:** 2026-09-07

## Purpose

Add a framework-neutral `./wari create-project` command that wraps Composer's
`create-project` command and installs a new Composer project into the current
Wari project root.

The intended bootstrap flow is:

```bash
mkdir php-app
cd php-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project vendor/project
```

After the command completes, `wari`, `.wari/`, and the newly created Composer
project all live in `php-app/`. The command and its documentation must remain
framework-neutral. Framework-specific examples belong only in their respective
compatibility guides.

## Background

Composer `create-project` creates a project in a new or empty target directory.
Installing Wari first makes the desired project root non-empty because it
contains `wari` and `.wari/`. Passing the current directory directly to
Composer therefore fails.

Wari will solve this by asking Composer to create the project in an empty,
temporary sibling directory. After Composer succeeds, Wari will validate and
publish the staged project entries into the Wari project root while preserving
the local runtime.

## Command Interface

The public interface is:

```text
./wari create-project [--yes] <package> [version] [composer-options]
```

Examples:

```bash
./wari create-project vendor/project
./wari create-project vendor/project "^2.0"
./wari create-project --yes vendor/project --no-interaction
./wari create-project vendor/project --yes --prefer-dist
```

Rules:

- `<package>` is required and must be the first non-Wari argument.
- Wari accepts `--yes` anywhere in the command arguments, removes every
  occurrence, and never passes it to Composer.
- Wari inserts the staging directory as Composer's directory positional
  argument.
- Arguments after `<package>`, other than `--yes`, retain their order and are
  passed to Composer after the injected directory. This supports Composer's
  optional version and command options.
- The user cannot supply a target directory. The target is always the current
  Wari project root.
- `./wari create-project --help` and `./wari create-project -h` show help for
  the Wari wrapper without invoking Composer.
- Missing or invalid arguments produce a concise usage message and a non-zero
  exit status.
- Composer options such as `--no-interaction` remain Composer options and are
  forwarded unchanged.

The dispatcher help will list `create-project` alongside the existing generic
Wari commands. The dispatcher delegates it to an internal executable wrapper
at `.wari/create-project`.

## Project-Root Preflight

Before prompting or creating a staging directory, the wrapper resolves and
displays the physical absolute path of the current Wari project root.

The root must contain exactly these two top-level entries:

```text
.wari/
wari
```

The wrapper rejects the operation if either required entry is missing or
invalid, or if any additional top-level entry exists. This deliberately
excludes otherwise harmless files such as `.gitignore` or `README.md`: the
strict rule prevents ambiguous merge and overwrite behavior.

The `.wari/` entry must be the runtime directory used by the active dispatcher,
and `wari` must be the active executable dispatcher. Symbolic-link surprises
and broken runtime layouts are rejected before Composer runs.

## Confirmation and Automation

Interactive execution prints the physical absolute destination path and asks
for explicit confirmation:

```text
Wari will create a Composer project in:

  /full/path/to/php-app

Only ./wari and ./.wari/ will be preserved.
Continue? [y/N]
```

Only an explicit `y` or `Y` continues. An empty response or any other response
cancels without creating staging data or changing the root.

The prompt reads from `/dev/tty`, consistent with the installer. If no terminal
is available and `--yes` was not supplied, the wrapper exits non-zero and tells
the caller to pass `--yes` for automation. With `--yes`, Wari skips only its own
confirmation; Composer retains its normal interaction behavior unless the user
also passes Composer's `--no-interaction` option.

## Staging Architecture

The staging directory is created in the parent directory of the project root,
not inside the root or a system-wide temporary location. Its name combines the
project basename with a Wari-specific marker and an unpredictable suffix, for
example:

```text
/projects/.php-app.wari-create.A1B2C3
```

Keeping staging beside the destination ensures both paths are on the same
filesystem and allows top-level entries to be published with rename operations.
The wrapper must support project paths containing spaces and shell metacharacters
without word splitting or glob expansion.

Wari invokes its bundled Composer equivalent to:

```text
composer create-project <package> <absolute-staging-path> [remaining arguments]
```

Composer and package scripts continue to use Wari's bundled PHP through the
existing `PHP_BINARY`, `PATH`, and `WARI_COMPOSER_CONTEXT` behavior.

## Staged-Project Validation

Composer's zero exit status is necessary but not sufficient for publication.
Before moving anything, Wari verifies that:

- the staging directory is the exact safe directory created by this process;
- the staging directory contains a regular `composer.json` file;
- the staged project has no top-level `wari` entry;
- the staged project has no top-level `.wari` entry; and
- the destination root still passes the strict preflight check.

A staged `wari` or `.wari` would collide with the runtime and is rejected rather
than overwritten, renamed, or merged.

## Publication

After validation, Wari enumerates every top-level staging entry using a
null-delimited mechanism that includes dotfiles. It moves each entry into the
project root without overwriting an existing destination.

The wrapper records each entry it owns before attempting its move so cleanup
can distinguish generated project data from unrelated files. Before every
move, it checks that the destination name is still absent. If another process
creates a conflicting root entry, publication stops; Wari preserves the
concurrently created entry and cleans up only data owned by this invocation.

On success, Wari removes the now-empty staging directory and prints a neutral
message:

```text
Composer project created successfully in:

  /full/path/to/php-app

Wari is ready:
  ./wari php --version
  ./wari composer --version
```

The output must not mention Artisan, Laravel, Symfony Console, or any other
framework-specific command. It must not recommend `composer install`, because
Composer `create-project` normally installs the new project's dependencies.

## Failure and Cleanup

The wrapper installs traps before creating staging data. Cleanup covers normal
errors and the `INT` and `TERM` signals.

- If Composer fails, Wari removes the complete staging directory and exits with
  Composer's exit status.
- If validation fails, Wari removes staging and leaves `wari` and `.wari/`
  untouched.
- If publication fails, Wari removes only successfully published entries owned
  by this invocation, then removes staging.
- Any unrelated destination entry created concurrently is preserved.
- Cancellation at the confirmation prompt creates nothing and requires no
  cleanup.
- Wari never deletes, replaces, or merges the destination's `wari` or `.wari/`
  entries.

Before recursive cleanup, the candidate staging path must pass strict safety
checks: it must be a direct child of the expected parent, match the expected
Wari staging prefix with a non-empty random suffix, differ from the project
root, and equal the staging path recorded by the current process. Cleanup must
use quoted, explicit paths and must not depend on an unresolved glob or an
unvalidated environment variable.

If Wari cannot prove that a path is owned and safe, it must refuse to delete
that path and report the cleanup problem.

## Exit Status

- Input, preflight, confirmation-environment, validation, or publication
  failures return a Wari non-zero status.
- A user declining confirmation returns success because no requested mutation
  was attempted.
- Composer failures return Composer's original exit status after cleanup.
- Successful creation returns zero.

## Implementation Boundaries

The installer remains the source of generated wrapper and dispatcher content.
Implementation will extend `generate_wrappers()` with the focused
`.wari/create-project` executable and extend `generate_dispatcher()` to expose
it publicly.

No framework detection, package-name allowlist, framework-specific post-install
command, or special handling for Laravel is included. Wari delegates project
creation semantics to Composer.

## Test Strategy

Offline wrapper tests will use fake Composer/PHP behavior and temporary
directories. They must cover:

- dispatcher help and delegation for `create-project`;
- missing package and wrapper help;
- strict root acceptance with only `wari` and `.wari/`;
- rejection of every additional root entry, including dotfiles and symlinks;
- interactive confirmation showing the absolute root;
- declining confirmation without mutation;
- failure without a TTY and without `--yes`;
- `--yes` before and after the package;
- removal of `--yes` before Composer invocation;
- forwarding package, version, and Composer options in order;
- injection of an absolute sibling staging target;
- successful publication of files, directories, dotfiles, and `.git/`;
- support for destination paths containing spaces;
- rejection of staged `wari` and `.wari` collisions;
- cleanup after Composer, validation, and publication failures;
- preservation of a destination entry created concurrently;
- Composer exit-status propagation;
- neutral success output with no framework-specific wording; and
- absence of abandoned Wari staging directories after success or expected
  failure.

Existing installer and wrapper suites must continue to pass. An opt-in live
test should exercise at least one small, framework-neutral Composer project to
verify real Composer archive extraction and script execution without making a
specific framework part of Wari's product behavior.

## Documentation

The main README will document the neutral bootstrap flow using `php-app` and
`vendor/project` placeholders. It will explain interactive confirmation,
`--yes`, the strict-empty-root rule, and automatic staging cleanup.

Compatibility guides may replace their temporary-bootstrap-and-move steps with
`./wari create-project <package>` examples for the project each guide covers.
Those examples are compatibility evidence only; the command implementation and
main README remain framework-neutral.

## Out of Scope

- Creating a named child destination directory.
- Installing into a root that contains files other than `wari` and `.wari/`.
- Updating or reinstalling Wari.
- Framework detection or framework-specific setup.
- Automatically running framework CLIs after project creation.
- Preserving failed staging contents for debugging.
- Cross-filesystem publication.
