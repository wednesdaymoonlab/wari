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

## Command layout

The manual test workspace used one Wari installation with applications in child
directories:

```text
playground/
├── wari
├── .wari/
└── example-app/
```

Commands run from `playground/` therefore use `./wari`; commands run from an
application use `../wari`. In a normal repository where Wari is installed in
the application root, replace `../wari` with `./wari`.

Each guide separates observed results from upstream features that have not yet
been tested. Stop any foreground server with `Ctrl-C` after verification.
