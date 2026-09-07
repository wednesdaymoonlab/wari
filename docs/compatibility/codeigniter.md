# CodeIgniter

Status: **Partial** with CodeIgniter 4.7.4. CLI and FrankenPHP worker mode work;
the framework's built-in `spark serve` flow is not compatible with Wari's
current `php -S` translation.

## Install

```bash
./wari composer create-project codeigniter4/appstarter codeigniter-app
```

## CLI

The `spark` file is a PHP entry point and works through Wari:

```bash
./wari php codeigniter-app/spark
./wari php codeigniter-app/spark routes
./wari php codeigniter-app/spark config:check
```

## Worker mode

Install CodeIgniter's FrankenPHP worker files:

```bash
./wari php codeigniter-app/spark worker:install
```

Run from the application directory so relative paths in `Caddyfile` resolve
correctly:

```bash
cd codeigniter-app
../wari frankenphp run --config Caddyfile
```

In another terminal:

```bash
curl -I http://127.0.0.1:8080
```

## Tests

From the directory containing `wari`:

```bash
./wari composer --working-dir=codeigniter-app test
```

## Known limitation

Do not use this as the Wari compatibility test server:

```bash
./wari php codeigniter-app/spark serve
```

`spark serve` launches native PHP's server with CodeIgniter's custom
`rewrite.php` router and restart logic. Wari translates `php -S` to
FrankenPHP's front-controller server instead of executing the router script,
which can cause repeated restarts and `Command .../rewrite.php not found`.
Use the generated worker-mode `Caddyfile` instead.
