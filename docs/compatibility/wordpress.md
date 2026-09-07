# WordPress

Status: **Verified** with WordPress 7.1 and a temporary MySQL container.

WordPress is distributed as an application archive rather than a Composer
project, so its source installation is independent of Wari.

## Install Wari

After extracting or cloning WordPress, install Wari in the WordPress root:

```bash
cd wordpress-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
```

## Database

Start a disposable MySQL server:

```bash
docker run --name wari-wordpress-db --rm \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=wordpress \
  -e MYSQL_USER=wordpress \
  -e MYSQL_PASSWORD=wordpress \
  -p 3307:3306 \
  mysql:8.4
```

Use these values in `wp-config.php` or the browser installer:

| Setting | Value |
| --- | --- |
| Database | `wordpress` |
| User | `wordpress` |
| Password | `wordpress` |
| Host | `127.0.0.1:3307` |

## Web server

```bash
./wari php -S 127.0.0.1:8082 \
  -t . \
  index.php
```

Then open `http://127.0.0.1:8082` and complete the installer. A basic HTTP check
is:

```bash
curl -I http://127.0.0.1:8082
```

## Cleanup

Stop the PHP server with `Ctrl-C`. In the database terminal, use `Ctrl-C` or:

```bash
docker stop wari-wordpress-db
```

Because the container uses `--rm`, Docker removes it after it stops. WordPress
files and uploaded content remain in the application directory.

## Notes

- MySQL connectivity through the extension bundled with FrankenPHP was
  verified.
- WP-CLI and alternative databases were not tested.
- Wari does not install or manage the database server.
