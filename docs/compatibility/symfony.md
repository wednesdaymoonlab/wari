# Symfony

Status: **Verified** with Symfony 8.1.6.

## Install

The tested application is a Symfony web application with Flex, Doctrine, Twig,
AssetMapper, and PHPUnit installed through Composer. A reproducible setup from
the directory containing `wari` is:

```bash
./wari composer create-project symfony/skeleton:"8.1.*" symfony-app
./wari composer --working-dir=symfony-app require webapp
```

## CLI

```bash
./wari php symfony-app/bin/console --version
./wari php symfony-app/bin/console about
./wari php symfony-app/bin/console debug:router
```

## Web server

```bash
./wari php -S 127.0.0.1:8081 -t symfony-app/public
curl -I http://127.0.0.1:8081
```

## Composer and tests

```bash
./wari composer --working-dir=symfony-app install
./wari php symfony-app/bin/phpunit
```

If the project does not include `bin/phpunit`, use its installed PHPUnit binary:

```bash
./wari php symfony-app/vendor/bin/phpunit -c symfony-app/phpunit.dist.xml
```

## Notes

- Symfony Flex post-install scripts and console commands were verified.
- Doctrine database operations were not part of this pass.
- FrankenPHP supports Symfony worker mode through the Symfony Runtime, but that
  configuration has not been verified with Wari yet.
