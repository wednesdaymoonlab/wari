# Supervisor

Supervisor generation supports Linux and macOS. Supervisor must already be
installed and have a parent `supervisord.conf` that includes program files.

Generate and review a program:

```bash
./wari service generate supervisor \
  --profile=classic --user=app --name=my-app >my-app.conf
less my-app.conf
```

Create the state directory using the ownership command printed by Wari. The
generated program writes its rotating combined log to `service.log` beneath
that directory. On Linux the default is `/var/lib/wari/my-app`; on macOS it is
under the selected user's `Library/Application Support/Wari/my-app`.

Inspect the parent configuration's `[include]` `files=` pattern and install the
program into a matched directory. `/etc/supervisor/conf.d/my-app.conf` is a
common Linux location, but it is not universal. macOS has no single standard
include directory.

Use the same absolute parent configuration path for every operation:

```bash
sudo supervisorctl -c /absolute/path/supervisord.conf reread
sudo supervisorctl -c /absolute/path/supervisord.conf update
sudo supervisorctl -c /absolute/path/supervisord.conf status my-app
```

For Octane and Caddyfile, run the exact application reload command printed by
the generator. Classic must be restarted:

```bash
sudo supervisorctl -c /absolute/path/supervisord.conf restart my-app
```

After pulling code, run `./wari setup --yes` and `./wari composer install`
before reloading or restarting. If the generated program changes, replace the
included file and run `reread` followed by `update`.

To remove it, stop the program, remove its included file, and update Supervisor:

```bash
sudo supervisorctl -c /absolute/path/supervisord.conf stop my-app
sudo supervisorctl -c /absolute/path/supervisord.conf reread
sudo supervisorctl -c /absolute/path/supervisord.conf update
```

Review and remove the external state directory separately when its Caddy data
and rotating logs are no longer needed.
