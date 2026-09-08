# systemd

systemd generation is available only on Linux. Generate and review a unit:

```bash
./wari service generate systemd \
  --profile=classic --user=www-data --name=my-app >my-app.service
less my-app.service
```

With the default state path, the unit uses `StateDirectory=wari/my-app` and
systemd creates `/var/lib/wari/my-app`. If `--state-dir` supplies another
absolute path, create it first with the service user as owner, following the
command printed by Wari.

Install and start the reviewed unit:

```bash
sudo install -m 0644 my-app.service /etc/systemd/system/my-app.service
sudo systemctl daemon-reload
sudo systemctl enable --now my-app.service
sudo systemctl status my-app.service
journalctl -u my-app.service
```

Octane and Caddyfile profiles include `ExecReload`; use:

```bash
sudo systemctl reload my-app.service
```

Classic has no reload and must use `sudo systemctl restart my-app.service`.
After pulling code, run `./wari setup --yes` and `./wari composer install`
before the appropriate reload or restart. If regenerated unit content changes,
install it again and run `sudo systemctl daemon-reload` before restarting.

To remove the service:

```bash
sudo systemctl disable --now my-app.service
sudo rm /etc/systemd/system/my-app.service
sudo systemctl daemon-reload
```

Review and remove its external state directory separately only after deciding
that its Caddy data and logs are no longer needed.
