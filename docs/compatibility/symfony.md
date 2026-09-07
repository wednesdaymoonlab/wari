# Symfony

Status: **Verified** with Symfony 8.1.6.

## Install

The tested application is a Symfony web application with Flex, Doctrine, Twig,
AssetMapper, and PHPUnit installed through Composer. First create the
[temporary Wari bootstrap](README.md#new-composer-project-without-global-php).
From `wari-bootstrap/`, run:

```bash
./wari composer create-project symfony/skeleton:"8.1.*" ../symfony-app
mv wari .wari ../symfony-app/
cd ../symfony-app
rmdir ../wari-bootstrap
./wari composer require webapp
```

## CLI

```bash
./wari php bin/console --version
./wari php bin/console about
./wari php bin/console debug:router
```

## Web server

```bash
./wari php -S 127.0.0.1:8081 -t public
curl -I http://127.0.0.1:8081
```

## Composer and tests

```bash
./wari composer install
./wari php bin/phpunit
```

If the project does not include `bin/phpunit`, use its installed PHPUnit binary:

```bash
./wari php vendor/bin/phpunit -c phpunit.dist.xml
```

## Notes

- Symfony Flex post-install scripts and console commands were verified.
- Doctrine database operations were not part of this pass.
- FrankenPHP supports Symfony worker mode through the Symfony Runtime, but that
  configuration has not been verified with Wari yet.
