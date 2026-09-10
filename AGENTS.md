# Agent Instructions

## Critical rules

- Never run `git add`, `git commit`, or `git push` in this repository.
- Leave all changes unstaged so the user can review and manage Git history.
- Read-only Git commands such as `git status`, `git diff`, and `git log` are allowed.

## Release version checklist

Before telling the user that a release is ready or recommending that they create a
release tag:

1. Update `WARI_VERSION` in both `wari` and `install.sh` to the intended version.
2. Update all active version references in the README and test fixtures. Preserve
   references that intentionally document or test historical versions.
3. Search the active launcher, installer, documentation, and tests for stale
   references to the previous version and review every match.
4. Run the complete offline test suite, `git diff --check`, shell syntax checks,
   and `./wari --version`. The reported version must match the intended tag.
5. Run the live clean-install test when preparing a public release. Confirm that
   the installed launcher reports the intended version and that the Laravel,
   Composer, and HTTP smoke checks pass.
6. Confirm that the commit the user will tag contains the version bump. Never
   recommend creating or pushing the tag before that commit is on `main`.
7. After the user pushes, verify the remote tag and the raw `main` installer. The
   tag name, `wari` version, and `install.sh` version must all agree.
8. If an incorrect tag has already been pushed, do not recommend rewriting it.
   Correct the version and use the next patch release instead.
