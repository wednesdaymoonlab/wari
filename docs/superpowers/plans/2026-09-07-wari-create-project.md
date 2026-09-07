# Wari `create-project` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a framework-neutral `./wari create-project` command that safely creates a Composer project in the current Wari-only directory.

**Architecture:** Generate a focused `.wari/create-project` Bash wrapper from `install.sh` and expose it through the existing root dispatcher. The wrapper validates the root, confirms the physical destination, runs bundled Composer against a sibling staging directory, then publishes all staged top-level entries with ownership-aware rollback and guarded cleanup.

**Tech Stack:** Bash 3.2-compatible shell, Composer CLI, FrankenPHP PHP CLI, existing shell test harness

**Spec:** `docs/superpowers/specs/2026-09-07-wari-create-project-design.md`

## Global Constraints

- Never run `git add`, `git commit`, or `git push`; leave every change unstaged for user review.
- Support Linux x86_64/ARM64 and macOS Intel/Apple Silicon with Bash 3.2 compatibility.
- The command installs only into the current Wari project root; it never accepts a destination directory.
- Before work starts, the root must contain exactly the active `wari` executable and `.wari/` runtime directory.
- `--yes` skips only Wari's confirmation and is never forwarded to Composer.
- The main README and success output must be framework-neutral and use `php-app` plus `vendor/project` placeholders.
- Never overwrite, merge, move, or delete the root `wari` or `.wari/` entries.
- Every recursive deletion must use a quoted path that passed direct-child, prefix, suffix, ownership, and project-root inequality checks.
- Composer failures must retain their original exit status after cleanup.

---

## File Structure

- `install.sh`: remain the single distributable source; generate the new internal wrapper and extend dispatcher help/delegation.
- `tests/test-create-project.sh`: focused offline command tests with isolated Wari-only roots and a fake Composer executable.
- `tests/test-installer.sh`: verify a normal installation publishes the new executable wrapper and smoke-checks dispatcher help without invoking project creation.
- `tests/test-live-install.sh`: opt-in real Composer `create-project` smoke check using a separate copied Wari runtime.
- `README.md`: document the neutral `php-app` bootstrap flow, confirmation, automation, root restrictions, and cleanup; remove framework-specific examples from the main usage narrative.
- `docs/compatibility/README.md`: replace the temporary-bootstrap relocation workaround with the new general command flow.
- `docs/compatibility/{cakephp,codeigniter,laravel,slim,symfony}.md`: update only each guide's installation recipe; keep framework-specific commands inside their respective evidence guides.

---

### Task 1: Public Command, Argument Contract, Root Preflight, and Confirmation

**Files:**

- Create: `tests/test-create-project.sh`
- Modify: `install.sh:613-886`

**Interfaces:**

- Consumes: `generate_wrappers <wari-dir>` and `generate_dispatcher <wari-dir>` from `install.sh`.
- Produces: executable `.wari/create-project`; dispatcher route `./wari create-project`; CLI `./wari create-project [--yes] <package> [version] [composer-options]`.

- [x] **Step 1: Create the focused test harness and write failing dispatcher/help tests**

Create `tests/test-create-project.sh` with the standard harness setup and an isolated project whose root contains only `.wari/` and `wari`:

```bash
#!/usr/bin/env bash

set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=test-helper.sh
source "$TEST_DIR/test-helper.sh"
# shellcheck source=../install.sh
source "$CORE_DIR/install.sh"

CREATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wari-create-project-test.XXXXXX")"
CREATE_TMP="$(CDPATH= cd -- "$CREATE_TMP" && pwd -P)"
trap 'rm -rf -- "$CREATE_TMP"' EXIT

PROJECT="$CREATE_TMP/php app"
WARI="$PROJECT/.wari"
DISPATCHER="$PROJECT/wari"
mkdir -p "$WARI/runtime"
printf 'fake composer' >"$WARI/runtime/composer.phar"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WARI/runtime/frankenphp"
chmod 755 "$WARI/runtime/frankenphp"
generate_wrappers "$WARI"
generate_dispatcher "$WARI"
mv -- "$WARI/wari" "$DISPATCHER"

assert_eq '2' "$(find "$PROJECT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    'create-project fixture starts with exactly two root entries'
assert_eq '0' "$(test -x "$WARI/create-project"; printf '%s' "$?")" \
    'wrapper generator creates executable create-project command'

HELP_OUTPUT="$($DISPATCHER --help)"
assert_contains "$HELP_OUTPUT" 'create-project' 'dispatcher help lists create-project'

COMMAND_HELP="$($DISPATCHER create-project --help)"
assert_contains "$COMMAND_HELP" \
    'Usage: ./wari create-project [--yes] <package> [version] [composer-options]' \
    'create-project has focused usage help'

finish_tests
```

- [x] **Step 2: Run the new test and confirm the interface is absent**

Run:

```bash
bash tests/test-create-project.sh
```

Expected: FAIL because `.wari/create-project` is missing and dispatcher help does not list the command.

- [x] **Step 3: Add failing argument and strict-preflight cases**

Before `finish_tests`, add cases that execute the generated wrapper rather than sourcing it:

```bash
set +e
MISSING_OUTPUT="$($DISPATCHER create-project --yes 2>&1)"
MISSING_STATUS=$?
set -e
assert_eq '2' "$MISSING_STATUS" 'create-project rejects a missing package'
assert_contains "$MISSING_OUTPUT" 'Usage:' 'missing package prints usage'

printf 'existing data\n' >"$PROJECT/README.md"
set +e
NONEMPTY_OUTPUT="$($DISPATCHER create-project --yes vendor/project 2>&1)"
NONEMPTY_STATUS=$?
set -e
assert_eq '1' "$NONEMPTY_STATUS" 'create-project rejects an additional root entry'
assert_contains "$NONEMPTY_OUTPUT" 'README.md' 'preflight identifies the additional entry'
rm -f -- "$PROJECT/README.md"

ln -s missing-target "$PROJECT/extra-link"
assert_fails 'create-project rejects a broken root symlink' \
    "$DISPATCHER" create-project --yes vendor/project
rm -f -- "$PROJECT/extra-link"
```

Also create fresh fixture roots that verify rejection when `wari` is a symlink,
`.wari/` is a symlink, the dispatcher is not executable, or required runtime
files are absent. Use explicit fixture paths under `$CREATE_TMP`; do not mutate
and reuse the primary fixture for these structural cases.

- [x] **Step 4: Generate the wrapper shell with its usage, parser, and preflight**

In `generate_wrappers()`, add a single-quoted heredoc that creates
`$wari_dir/create-project`. Its initial structure must define and call these
focused functions:

```bash
create_project_usage() {
    printf '%s\n' \
        'Usage: ./wari create-project [--yes] <package> [version] [composer-options]' \
        '' \
        'Create a Composer project in the current Wari project directory.' \
        'Use --yes to accept Wari confirmation in automation.'
}

create_project_error() {
    printf 'Error: %s\n' "$1" >&2
}

validate_project_root() {
    local candidate name count=0

    [[ -d "$WARI_DIR" && ! -L "$WARI_DIR" ]] || {
        create_project_error "Wari runtime directory is invalid: $WARI_DIR"
        return 1
    }
    [[ -f "$PROJECT_ROOT/wari" && -x "$PROJECT_ROOT/wari" &&
        ! -L "$PROJECT_ROOT/wari" ]] || {
        create_project_error "Wari dispatcher is invalid: $PROJECT_ROOT/wari"
        return 1
    }
    [[ -x "$WARI_DIR/php" && -x "$WARI_DIR/composer" &&
        -f "$WARI_DIR/runtime/composer.phar" ]] || {
        create_project_error 'Wari runtime is incomplete'
        return 1
    }

    while IFS= read -r -d '' candidate; do
        name="${candidate##*/}"
        case "$name" in
            wari|.wari) ;;
            *)
                create_project_error "project directory contains an unsupported entry: $name"
                return 1
                ;;
        esac
        count=$((count + 1))
    done < <(find "$PROJECT_ROOT" -mindepth 1 -maxdepth 1 -print0)

    [[ "$count" -eq 2 ]] || {
        create_project_error 'project directory must contain only wari and .wari/'
        return 1
    }
}
```

Use Bash arrays to remove every `--yes` without `eval`, word splitting, or
argument reordering. Treat `-h` or `--help` as Wari command help only when it is
the sole argument; after a package, those flags belong to Composer. After
stripping Wari flags, reject an empty package and a package beginning with `-`;
assign the first remaining element to `PACKAGE` and preserve the remaining
array as `COMPOSER_ARGUMENTS`.

Resolve paths without relying on the caller's working directory:

```bash
WARI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$WARI_DIR")" && pwd -P)"
PROJECT_PARENT="$(CDPATH= cd -- "$(dirname -- "$PROJECT_ROOT")" && pwd -P)"
PROJECT_NAME="${PROJECT_ROOT##*/}"
```

Add `$wari_dir/create-project` to the existing `chmod 755` list. Extend
dispatcher usage with a neutral description and extend its delegation case:

```bash
php|composer|create-project|serve|frankenphp)
```

- [x] **Step 5: Add and exercise confirmation behavior**

Implement the prompt after preflight and before staging creation:

```bash
printf '%s\n\n  %s\n\n%s\n' \
    'Wari will create a Composer project in:' \
    "$PROJECT_ROOT" \
    'Only ./wari and ./.wari/ will be preserved.' >&4
printf 'Continue? [y/N]: ' >&4
IFS= read -r answer <&3 || return 1
case "$answer" in
    y|Y) return 0 ;;
    *) return 2 ;;
esac
```

The production `create_project_main` function opens descriptors 3 and 4 on
`/dev/tty`. If opening the terminal fails, print `pass --yes for automation`
and return non-zero. Keep `confirm_create_project` isolated and make
`create_project_main "$@"` the generated script's final line. Test confirmation
without a production bypass by making a sourceable copy and supplying fixture
descriptors:

```bash
sed '$d' "$WARI/create-project" >"$CREATE_TMP/create-project-functions"
(
    # shellcheck disable=SC1090
    source "$CREATE_TMP/create-project-functions"
    printf 'y\n' >"$CREATE_TMP/confirm.in"
    exec 3<"$CREATE_TMP/confirm.in" 4>"$CREATE_TMP/confirm.out"
    confirm_create_project
)
assert_contains "$(<"$CREATE_TMP/confirm.out")" "$PROJECT" \
    'confirmation displays the physical absolute root'
```

Repeat with `Y`, blank input, and `n`. Assert `y`/`Y` return zero while blank
and `n` take the cancellation result that `create_project_main` translates to
a clean zero exit without mutation. Do not add a production environment-variable
test bypass.

Add a direct non-TTY test with stdin redirected from `/dev/null`; assert failure
without `--yes`. Add a fake Composer that writes its arguments outside the root,
then assert both leading and trailing `--yes` reach the Composer phase without
opening `/dev/tty` and never appear in captured Composer arguments.

- [x] **Step 6: Run the focused tests and existing wrapper suite**

Run:

```bash
bash tests/test-create-project.sh
bash tests/test-wrappers.sh
```

Expected: both suites PASS. Confirm no command created an entry under the
primary root because the fake Composer cases in this task stop before
publication.

- [x] **Step 7: Review the first deliverable without staging it**

Run:

```bash
git diff --check
git diff -- install.sh tests/test-create-project.sh
git status --short
```

Expected: no whitespace errors; only intended unstaged files appear. Do not run
`git add` or `git commit`.

---

### Task 2: Composer Staging, Validation, Publication, and Rollback

**Files:**

- Modify: `tests/test-create-project.sh`
- Modify: `install.sh` inside the generated `.wari/create-project` heredoc

**Interfaces:**

- Consumes: parsed `PACKAGE`, `COMPOSER_ARGUMENTS`, `PROJECT_ROOT`,
  `PROJECT_PARENT`, `PROJECT_NAME`, and `.wari/composer` from Task 1.
- Produces: sibling staging lifecycle; `is_safe_create_staging <path>`;
  `cleanup_create_project`; complete project publication into `PROJECT_ROOT`.

- [x] **Step 1: Replace the minimal fake Composer with a reusable project-producing fixture**

Add a `write_fake_composer <path>` helper to `tests/test-create-project.sh` that
creates this executable behavior:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

capture="${FAKE_COMPOSER_CAPTURE:?}"
printf 'argc=%s\n' "$#" >"$capture"
index=0
for argument in "$@"; do
    printf 'arg%s=<%s>\n' "$index" "$argument" >>"$capture"
    index=$((index + 1))
done

target="${3-}"
case "${FAKE_COMPOSER_MODE:-success}" in
    fail) exit "${FAKE_COMPOSER_EXIT:-17}" ;;
    missing-composer-json)
        printf 'generated\n' >"$target/generated.txt"
        ;;
    wari-collision)
        printf '{}\n' >"$target/composer.json"
        printf 'collision\n' >"$target/wari"
        ;;
    runtime-collision)
        printf '{}\n' >"$target/composer.json"
        mkdir "$target/.wari"
        ;;
    concurrent-entry)
        printf '{"name":"vendor/project"}\n' >"$target/composer.json"
        printf 'generated\n' >"$target/generated.txt"
        printf 'unrelated\n' >"${FAKE_PROJECT_ROOT:?}/concurrent.txt"
        ;;
    block)
        printf '%s\n' "$target" >"${FAKE_STAGING_CAPTURE:?}"
        trap 'exit 130' INT
        trap 'exit 143' TERM
        while :; do sleep 1; done
        ;;
    success)
        printf '{"name":"vendor/project"}\n' >"$target/composer.json"
        printf 'visible\n' >"$target/generated.txt"
        printf 'hidden\n' >"$target/.env"
        mkdir -p "$target/src" "$target/.git"
        printf '<?php\n' >"$target/src/App.php"
        printf '[core]\n' >"$target/.git/config"
        ;;
esac
```

The test fixture will replace the generated `.wari/composer` only after all
wrappers are generated. `FAKE_COMPOSER_CAPTURE` must point outside the project
root so strict preflight remains meaningful.

- [x] **Step 2: Add failing success-path and argument-forwarding tests**

Create a fresh Wari-only root whose basename contains spaces, run:

```bash
FAKE_COMPOSER_CAPTURE="$CAPTURE" \
    "$DISPATCHER" create-project --yes vendor/project '^2.0' --prefer-dist
```

Assert exact argument positions:

```text
arg0=<create-project>
arg1=<vendor/project>
arg2=</absolute/parent/.php app.wari-create.XXXXXX>
arg3=<^2.0>
arg4=<--prefer-dist>
```

Also assert that `composer.json`, `generated.txt`, `.env`, `src/App.php`, and
`.git/config` exist in the root; `wari` and `.wari/` remain valid; the success
output contains the physical root and generic `./wari php --version` plus
`./wari composer --version`; and no sibling matching the Wari staging prefix
remains.

- [x] **Step 3: Implement safe staging creation and Composer invocation**

Create staging only after confirmation:

```bash
STAGING_PREFIX=".$PROJECT_NAME.wari-create."
STAGING_DIR="$(mktemp -d "${PROJECT_PARENT}/${STAGING_PREFIX}XXXXXX")"
```

Implement `is_safe_create_staging()` so it returns success only when all of
these hold:

```bash
[[ -n "$STAGING_DIR" ]]
[[ "$1" == "$STAGING_DIR" ]]
[[ "$1" != "$PROJECT_ROOT" ]]
[[ "$(dirname -- "$1")" == "$PROJECT_PARENT" ]]
[[ "${1##*/}" == "$STAGING_PREFIX"?* ]]
[[ "${1##*/}" != "$STAGING_PREFIX" ]]
[[ -d "$1" && ! -L "$1" ]]
```

Install `EXIT`, `INT`, and `TERM` traps immediately after `mktemp` succeeds.
Invoke Composer without `exec` so Wari retains cleanup control:

```bash
if "$WARI_DIR/composer" create-project "$PACKAGE" "$STAGING_DIR" \
    "${COMPOSER_ARGUMENTS[@]}"; then
    :
else
    composer_status=$?
    exit "$composer_status"
fi
```

The EXIT trap must save `$?`, perform guarded cleanup, and exit with the saved
status. Signal traps exit with 130 for `INT` and 143 for `TERM`.

- [x] **Step 4: Add failing staged-validation and Composer-failure tests**

Run separate fresh fixtures with fake modes `fail`, `missing-composer-json`,
`wari-collision`, and `runtime-collision`. Assert:

- fake exit 17 returns 17;
- all validation failures are non-zero;
- root still contains exactly `wari` and `.wari/`;
- both runtime paths remain executable/usable;
- no staging sibling remains; and
- collision content never replaces the Wari paths.

Add a root-race case where fake Composer creates `concurrent.txt` directly in
the destination before returning. Assert that post-Composer preflight aborts,
preserves `concurrent.txt`, publishes none of the staged entries, and removes
staging.

- [x] **Step 5: Implement validation and null-delimited publication**

After Composer succeeds, require a regular `STAGING_DIR/composer.json`, reject
both `STAGING_DIR/wari` and `STAGING_DIR/.wari` using `-e || -L`, then rerun
`validate_project_root`.

Publish with a null-delimited loop:

```bash
while IFS= read -r -d '' source; do
    name="${source##*/}"
    destination="$PROJECT_ROOT/$name"
    if [[ -e "$destination" || -L "$destination" ]]; then
        create_project_error "destination entry appeared during publication: $name"
        exit 1
    fi

    CURRENT_SOURCE="$source"
    CURRENT_DESTINATION="$destination"
    mv -- "$source" "$destination"
    PUBLISHED_ENTRIES+=("$destination")
    CURRENT_SOURCE=''
    CURRENT_DESTINATION=''
done < <(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -print0)
```

Use indexed arrays only; do not use associative arrays because macOS ships
Bash 3.2. Keep current source/destination fields set around `mv` so a signal
between the rename and array append cannot orphan untracked generated data.

- [x] **Step 6: Implement ownership-aware cleanup and failure tests**

`cleanup_create_project` must:

1. Save and disable traps to prevent re-entry.
2. If `CURRENT_DESTINATION` exists and `CURRENT_SOURCE` no longer exists,
   validate that the destination is a direct non-reserved child of
   `PROJECT_ROOT`, then remove that owned entry.
3. Walk `PUBLISHED_ENTRIES` in reverse order, validate each as a direct
   non-reserved child, and remove it with `rm -rf --`.
4. Remove `STAGING_DIR` only if `is_safe_create_staging "$STAGING_DIR"` passes.
5. Never remove a path named `wari` or `.wari`.
6. Report any refused cleanup path while preserving the original failure code.

Add a controlled publication-failure test by prepending a fixture `mv` shim to
`PATH`. The shim delegates to the real `mv` except when the source basename is
`src`; before returning failure it creates an unrelated `src` destination.
Assert previously published owned entries are removed, the shim-created `src`
is preserved, `wari` and `.wari/` remain, staging is removed, and the command
returns non-zero.

Add an `INT` test whose fake Composer records staging then blocks. Start the
dispatcher in the background, wait until the capture exists, send `INT`, wait
for status 130, and assert staging cleanup. Repeat with `TERM` and status 143.
Use bounded polling with `kill -0`; do not use an unbounded sleep.

- [x] **Step 7: Complete neutral success output and run the focused suite**

After every entry is published, remove the empty safe staging directory, clear
the staging and ownership state so the EXIT trap becomes a no-op, then print:

```text
Composer project created successfully in:

  <physical-project-root>

Wari is ready:
  ./wari php --version
  ./wari composer --version
```

Run:

```bash
bash tests/test-create-project.sh
```

Expected: PASS with no leftover `.PROJECT.wari-create.*` directories under the
test root's parent.

- [x] **Step 8: Run all offline regression suites**

Run:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
```

Expected: all suites PASS.

- [x] **Step 9: Review the staging deliverable without staging it in Git**

Run:

```bash
git diff --check
git diff -- install.sh tests/test-create-project.sh
git status --short
```

Expected: no whitespace errors and no abandoned test artifacts. Do not run
`git add` or `git commit`.

---

### Task 3: Installer Layout Regression and Opt-In Live Composer Verification

**Files:**

- Modify: `tests/test-installer.sh:425-490`
- Modify: `tests/test-live-install.sh`

**Interfaces:**

- Consumes: generated `.wari/create-project` and dispatcher route from Tasks 1-2.
- Produces: installer layout coverage and real-network proof using Composer's
  framework-neutral `composer/hello-world` example package.

- [x] **Step 1: Add failing installer layout assertions**

Extend the successful-install fixture assertions in `tests/test-installer.sh`:

```bash
[[ -x "$project/.wari/php" && -x "$project/.wari/composer" &&
    -x "$project/.wari/create-project" ]] || return 3
```

Extend public smoke capture to invoke dispatcher help and assert that
`create-project` appears. Do not invoke project creation from this installer
test because its fake runtime is not a Composer project fixture.

- [x] **Step 2: Run installer tests and confirm the generated layout is covered**

Run:

```bash
bash tests/test-installer.sh
```

Expected: PASS after Tasks 1-2; if the new chmod/publication path is incomplete,
the new assertion must fail before proceeding.

- [x] **Step 3: Add a separate live create-project root**

In `tests/test-live-install.sh`, after the primary Wari installation smoke
checks and before creating the primary fixture's `composer.json`, add:

```bash
CREATE_PROJECT="$LIVE_ROOT/create project"
mkdir -p "$CREATE_PROJECT"
cp -R "$PROJECT/.wari" "$CREATE_PROJECT/.wari"
cp "$PROJECT/wari" "$CREATE_PROJECT/wari"
chmod 755 "$CREATE_PROJECT/wari"

(
    cd "$CREATE_PROJECT"
    ./wari create-project --yes composer/hello-world --no-interaction
)

if [[ ! -f "$CREATE_PROJECT/composer.json" ||
    ! -x "$CREATE_PROJECT/wari" ||
    ! -x "$CREATE_PROJECT/.wari/create-project" ]]; then
    printf 'Live create-project layout is incomplete.\n' >&2
    exit 1
fi

"$CREATE_PROJECT/wari" composer validate --no-interaction
if find "$LIVE_ROOT" -maxdepth 1 -name '.create project.wari-create.*' \
    -print -quit | grep -q .; then
    printf 'Live create-project left a staging directory behind.\n' >&2
    exit 1
fi
```

Keep this under the existing `WARI_RUN_LIVE=1` opt-in gate. The package comes
from Composer's own neutral `create-project` documentation example; no
framework becomes part of Wari behavior.

- [x] **Step 4: Run offline suites, then run the live suite when network approval is available**

Run offline first:

```bash
bash tests/test-installer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
```

Expected: PASS.

Then run the existing opt-in command:

```bash
WARI_RUN_LIVE=1 bash tests/test-live-install.sh
```

Expected: real Wari installation, neutral Composer project creation, Composer
validation, script checks, and loopback HTTP smoke test all PASS. If network is
unavailable, report the live test as unverified; do not claim it passed.

- [x] **Step 5: Review test changes without staging them**

Run:

```bash
git diff --check
git diff -- tests/test-installer.sh tests/test-live-install.sh
git status --short
```

Expected: only intended unstaged changes. Do not run `git add` or `git commit`.

---

### Task 4: Framework-Neutral Main Documentation and Compatibility Recipes

**Files:**

- Modify: `README.md`
- Modify: `docs/compatibility/README.md`
- Modify: `docs/compatibility/cakephp.md`
- Modify: `docs/compatibility/codeigniter.md`
- Modify: `docs/compatibility/laravel.md`
- Modify: `docs/compatibility/slim.md`
- Modify: `docs/compatibility/symfony.md`

**Interfaces:**

- Consumes: final command syntax and behavior from Tasks 1-3.
- Produces: neutral primary workflow plus accurate framework-specific evidence
  contained only in compatibility guides.

- [x] **Step 1: Write a failing documentation-policy check**

Run the following inspection and record the current matches before editing:

```bash
rg -n 'artisan|laravel-app|temporary Wari bootstrap|mv wari \.wari' README.md docs/compatibility
```

Expected before documentation changes: main README contains an Artisan example,
and compatibility guides contain the old bootstrap-and-move workaround.

- [x] **Step 2: Add the neutral new-project workflow to the main README**

Under installation, distinguish an existing PHP project from a new Composer
project. Use this exact neutral example:

```bash
mkdir php-app
cd php-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project vendor/project
```

Document these behaviors explicitly:

- destination confirmation displays the full physical path;
- only `wari` and `.wari/` may exist before creation;
- `--yes` skips Wari confirmation for automation;
- `--no-interaction` is separate and controls Composer interaction;
- failed creation removes generated project data and staging;
- project/package instructions should determine the next command.

Replace the main `./wari php artisan migrate` example with a neutral PHP entry
point such as `./wari php script.php`. Replace prose that uses `artisan` as its
relative-path example with `scripts/task.php`. Retain factual links to the
compatibility matrix; do not promote one framework in primary usage text.

- [x] **Step 3: Replace the general temporary-bootstrap workaround**

In `docs/compatibility/README.md`, replace “New Composer project without global
PHP” with the direct flow:

```bash
mkdir example-app
cd example-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project vendor/project
```

Explain that Wari uses an automatically cleaned sibling staging directory, so
users no longer move `wari` or `.wari/` manually.

- [x] **Step 4: Update each Composer-based compatibility guide**

Replace only the installation recipes with these command shapes:

```bash
# cakephp.md
mkdir cakephp-app && cd cakephp-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project "cakephp/app:^5.0" --prefer-dist

# codeigniter.md
mkdir codeigniter-app && cd codeigniter-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project codeigniter4/appstarter

# laravel.md
mkdir laravel-project && cd laravel-project
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project laravel/laravel

# slim.md
mkdir slim-app && cd slim-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project slim/slim-skeleton

# symfony.md
mkdir symfony-app && cd symfony-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project 'symfony/skeleton:8.1.*'
./wari composer require webapp
```

Do not change `wordpress.md`: it is not installed with Composer
`create-project`. Keep each framework's observed CLI/test notes in its own guide.

- [x] **Step 5: Verify documentation neutrality and command accuracy**

Run:

```bash
rg -n 'laravel-app|temporary Wari bootstrap|mv wari \.wari' README.md docs/compatibility
rg -n 'artisan|Laravel|Symfony|CakePHP|CodeIgniter|Slim' README.md
rg -n 'create-project' README.md docs/compatibility
```

Expected:

- first command returns no matches;
- second command matches only the factual compatibility-matrix/link section,
  not primary install/use examples;
- third command shows the neutral main workflow and the expected compatibility
  recipes.

- [x] **Step 6: Run complete verification**

Run:

```bash
bash -n install.sh tests/test-installer.sh tests/test-wrappers.sh \
    tests/test-create-project.sh tests/test-live-install.sh
bash tests/test-installer.sh
bash tests/test-wrappers.sh
bash tests/test-create-project.sh
git diff --check
git status --short
```

Expected: shell syntax check succeeds, all offline suites PASS, no whitespace
errors, and all implementation/spec/plan/documentation changes remain unstaged.
Do not run `git add`, `git commit`, or `git push`.

- [x] **Step 7: Provide the final review handoff**

Summarize:

- the exact public command and confirmation behavior;
- strict root and reserved-name protections;
- staging, rollback, and exit-status behavior;
- offline test counts/results and whether the opt-in live test ran;
- documentation neutrality changes; and
- the complete `git status --short` output so the user can manage Git history.
