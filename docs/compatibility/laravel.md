# Laravel

Status: **Verified** with Laravel Framework 13.30.1.

## Install

```bash
mkdir laravel-project
cd laravel-project
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
./wari create-project laravel/laravel
```

This exercises Composer archive extraction and Laravel's `@php` project-create
scripts, including environment creation, key generation, SQLite creation, and
migrations.

## CLI

```bash
./wari php artisan --version
./wari php artisan about
./wari php artisan migrate:status
```

## Composer scripts and development server

```bash
./wari composer run dev
```

Laravel's development script starts multiple child processes. Wari exports its
PHP wrapper through the `PHP_BINARY` environment variable, puts it at the front
of `PATH`, and supplies a namespace-level compatibility constant to
Composer-autoloaded classes when FrankenPHP leaves the global `PHP_BINARY`
constant empty. Artisan, Collision, Laravel Boost, and Composer children can
therefore continue using the project-local runtime. The frontend process still
requires Node.js and npm; Wari does not provide them.

For a PHP-only server:

```bash
./wari php -S 127.0.0.1:8080 -t public
curl -I http://127.0.0.1:8080
```

## Tests

```bash
./wari composer test
```

## Notes

- Composer commands that use `@php artisan` were verified.
- `artisan test --list-tests` was verified through Collision's direct
  `PHP_BINARY` usage.
- FrankenPHP's global `\PHP_BINARY` constant is still empty; Wari's
  compatibility bootstrap covers Composer-autoloaded namespaced classes.
- Composer-provided `-d` settings are accepted and ignored silently because
  FrankenPHP `php-cli` does not implement native PHP's complete `-d` behavior.
- Laravel Octane with FrankenPHP worker mode has not been tested yet.
