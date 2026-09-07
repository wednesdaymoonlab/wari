# CodeIgniter

Status: **Partial** with CodeIgniter 4.7.4. CLI and FrankenPHP worker mode work;
the framework's built-in `spark serve` flow is not compatible with Wari's
current `php -S` translation.

## Install

```bash
mkdir codeigniter-app
cd codeigniter-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
./wari create-project codeigniter4/appstarter
```

## CLI

The `spark` file is a PHP entry point and works through Wari:

```bash
./wari php spark
./wari php spark routes
./wari php spark config:check
```

## Worker mode

Install CodeIgniter's FrankenPHP worker files:

```bash
./wari php spark worker:install
```

Run from the application root so relative paths in `Caddyfile` resolve
correctly:

```bash
./wari frankenphp run --config Caddyfile
```

In another terminal:

```bash
curl -I http://127.0.0.1:8080
```

## Tests

```bash
./wari composer test
```

## Known limitation

Do not use this as the Wari compatibility test server:

```bash
./wari php spark serve
```

`spark serve` launches native PHP's server with CodeIgniter's custom
`rewrite.php` router and restart logic. Wari translates `php -S` to
FrankenPHP's front-controller server instead of executing the router script,
which can cause repeated restarts and `Command .../rewrite.php not found`.
Use the generated worker-mode `Caddyfile` instead.
