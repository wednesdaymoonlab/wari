# Laravel

Status: **Verified** with Laravel Framework 13.30.1.

## Install

First create the [temporary Wari bootstrap](README.md#new-composer-project-without-global-php).
From `wari-bootstrap/`, run:

```bash
./wari composer create-project laravel/laravel ../laravel-project
mv wari .wari ../laravel-project/
cd ../laravel-project
rmdir ../wari-bootstrap
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

Laravel's development script starts multiple child processes. Wari keeps its
PHP wrapper in `PHP_BINARY` and at the front of `PATH`, so Artisan and Composer
children continue to use the project-local runtime. The frontend process still
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
- Composer-provided `-d` settings are accepted and ignored silently because
  FrankenPHP `php-cli` does not implement native PHP's complete `-d` behavior.
- Laravel Octane with FrankenPHP worker mode has not been tested yet.
