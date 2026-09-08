# Production with Wari

Wari generates reviewable service-manager configuration for an existing PHP
project. The intended deployment flow is:

```text
pull or publish code -> ./wari setup --yes -> ./wari composer install
-> ./wari service generate -> review and install service
-> configure an external reverse proxy
```

Choose a [service profile](profiles.md), then follow the manager guide:

- [systemd](systemd.md) on Linux
- [Supervisor](supervisor.md) on Linux or macOS

A typical classic application can generate a unit without writing outside the
project:

```bash
./wari service generate systemd \
  --profile=classic --user=www-data >my-app.service
```

Configuration goes only to stdout. Diagnostics and installation guidance go
only to stderr, so review the redirected file before installing it. Generation
requires a ready runtime and validates the chosen profile's project files.

Wari does not install or configure systemd, Supervisor, TLS, Nginx, Apache,
secrets, databases, system accounts, privileges, atomic releases, or rollback.
It does not write a service file, invoke `sudo`, or start and stop a service.
Classic and Octane listeners accept only `127.0.0.1` or `::1`; expose them
through a separately secured reverse proxy.

Production XDG config and data paths are kept outside `.wari/`. This lets
`./wari setup` replace the machine-local runtime without deleting service
state. Wari never invents or overwrites `HOME`.
