# CakePHP

Status: **In progress** with CakePHP 5.4.2. Installation and console commands
are verified; web, database, and test-suite checks remain to be completed.

## Install

```bash
mkdir cakephp-app
cd cakephp-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari create-project "cakephp/app:^5.0" --prefer-dist
```

## CLI

CakePHP provides two console entry points:

- `bin/cake` is a POSIX shell launcher that searches `PATH` for `php`.
- `bin/cake.php` is the PHP entry point.

Use the PHP entry point to guarantee the project-local Wari runtime:

```bash
./wari php bin/cake.php version
./wari php bin/cake.php
./wari php bin/cake.php routes
```

Running `./wari php bin/cake version` is incorrect because it asks PHP to
parse a shell script. Running `bin/cake version` directly also fails on a
machine without system PHP because the shell launcher cannot find `php` in the
parent shell's `PATH`.

The shell launcher can be tested explicitly with Wari's internal wrapper:

```bash
PHP=./.wari/php bin/cake version
```

That internal path is useful for diagnosis, but `./wari php bin/cake.php` is
the stable public interface.

## Planned web check

CakePHP documents direct FrankenPHP support in its server command:

```bash
./wari php bin/cake.php server \
  --frankenphp \
  -H 127.0.0.1 \
  -p 8765
```

After starting it, verify from another terminal:

```bash
curl -I http://127.0.0.1:8765
```

This command is documented here as the next test, not as a verified result.

## Planned database and test checks

```bash
./wari php bin/cake.php bake migration CreateWariChecks message:string created
./wari php bin/cake.php migrations migrate
./wari php bin/cake.php migrations status
./wari composer test
```

SQLite configuration, migrations, ORM access, and PHPUnit remain unverified in
this pass. Update this guide and the matrix only after observing their results.
