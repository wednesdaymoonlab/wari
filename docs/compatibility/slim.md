# Slim

Status: **Verified** with Slim 4.15.3 using the Slim Skeleton application.

## Install

```bash
mkdir slim-app
cd slim-app
curl -fsSL https://raw.githubusercontent.com/wednesdaymoonlab/wari/main/install.sh | bash
./wari setup
./wari create-project slim/slim-skeleton
```

## Development server

The skeleton's Composer script uses `php -S localhost:8080 -t public`. Wari
translates that child command to FrankenPHP:

```bash
./wari composer start
```

Direct invocation is also supported:

```bash
./wari php -S 127.0.0.1:8080 -t public
```

Verify the default route:

```bash
curl -i http://127.0.0.1:8080/
```

## Tests

```bash
./wari composer test
```

The test application also used a small `GET /api/tarot/random` JSON endpoint to
verify routing, dependency injection, response headers, and JSON output.

## Notes

- Composer `start` and `test` scripts were verified.
- The older PHP-DI version in the tested skeleton emits deprecation messages on
  PHP 8.5. These messages come from the application dependency, not Wari. If
  displayed in HTTP output, they can corrupt JSON responses and headers.
- No database or worker-mode behavior was tested because the skeleton does not
  require either one.
