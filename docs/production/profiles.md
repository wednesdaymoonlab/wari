# Service profiles

Select a profile explicitly. Wari does not guess from project files.

## Classic

Use `classic` for broad framework compatibility and request isolation. It
requires a regular `index.php` in the document root and runs:

```text
./wari frankenphp php-server --listen 127.0.0.1:8000 --root <project>/public
```

Generate it with:

```bash
./wari service generate systemd --profile=classic --user=www-data
```

Options are `--root`, `--host`, `--port`, `--name`, `--state-dir`, and
`--stop-timeout`. Classic has no application reload operation; restart the
service when code or configuration changes.

## Laravel Octane

Use `octane` only when the Laravel application is intentionally prepared for
long-lived workers. Wari verifies the Octane package and published
`public/frankenphp-worker.php`, then runs:

```text
./wari php artisan octane:start --server=frankenphp --host=127.0.0.1 --port=8000
```

The optional `--workers` and `--max-requests` values are passed to Octane. A
profile reload runs:

```text
./wari php artisan octane:reload
```

Rendering successfully does not prove worker safety. Audit singleton state,
static values, request-scoped dependencies, memory growth, and deployment
behavior before production use. The default stop timeout is deliberately long
to allow active work to finish.

## Project Caddyfile

Use `caddyfile` when the framework or project owns its routing, worker, or
Caddy configuration:

```bash
./wari service generate supervisor \
  --profile=caddyfile --config=Caddyfile --user=app
```

Wari validates the file with the bundled runtime, starts it with:

```text
./wari frankenphp run --config <project>/Caddyfile
```

and reloads it with:

```text
./wari frankenphp reload --config <project>/Caddyfile
```

The Caddyfile is responsible for its own listener and routing policy. Review it
to ensure it matches the external proxy and exposure requirements.
