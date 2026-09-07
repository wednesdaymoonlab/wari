# Compatibility guides

These guides record reproducible manual checks performed with Wari. They are
not a promise that every feature or future release of a project will work.

## Test environment

The results below were recorded on 2026-09-07 with:

| Component | Version |
| --- | --- |
| Wari | 0.1.0 |
| FrankenPHP | 1.12.7 |
| PHP | 8.5.10 |
| Composer | 2.10.3 |
| Operating system | macOS, ARM64 |

Linux is supported by Wari, but this framework matrix has not yet been repeated
on Linux.

## Matrix

| Project | Type | Tested version | Install | CLI | Web | Database | Worker mode | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [Laravel](laravel.md) | Framework | 13.30.1 | Yes | Yes | Yes | SQLite | Not tested | Verified |
| [Symfony](symfony.md) | Framework | 8.1.6 | Yes | Yes | Yes | Not tested | Not tested | Verified |
| [WordPress](wordpress.md) | CMS | 7.1 | Manual | N/A | Yes | MySQL | N/A | Verified |
| [CodeIgniter](codeigniter.md) | Framework | 4.7.4 | Yes | Yes | Yes | Not tested | Yes | Partial |
| [Slim](slim.md) | Micro-framework | 4.15.3 | Yes | Yes | Yes | N/A | N/A | Verified |
| [CakePHP](cakephp.md) | Framework | 5.4.2 | Yes | Yes | Not tested | Not tested | Not tested | In progress |

Status meanings:

- **Verified**: the documented core install, CLI, and web flow was exercised.
- **Partial**: a useful flow works, but a documented limitation remains.
- **In progress**: installation or CLI was verified, but the planned checks are
  incomplete.
- **Not tested**: supported by the upstream project or planned, but not verified
  with Wari yet.

## Project-local layout

The guides use Wari from the framework or CMS project root:

```text
example-app/
├── .wari/
├── wari
├── composer.json
└── ...
```

All runtime commands therefore start with `./wari`. The generated `wari` and
`.wari/` paths are local development tools; do not commit them with application
source. Add both to the application's `.gitignore` when necessary:

```gitignore
/.wari/
/wari
```

### Existing project

For a cloned, downloaded, or otherwise existing project, install Wari directly
in its root and install dependencies:

```bash
cd example-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari composer install
```

### New Composer project without global PHP

Create an empty application directory, install Wari, and use Wari's dedicated
wrapper:

```bash
mkdir example-app
cd example-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project vendor/project
```

Replace `vendor/project` and `example-app` with the values shown in each guide.
Wari creates the Composer project in an automatically cleaned sibling staging
directory, then publishes it beside `wari` and `.wari/`; no manual relocation
is needed.

Each guide separates observed results from upstream features that have not yet
been tested. Stop any foreground server with `Ctrl-C` after verification.
