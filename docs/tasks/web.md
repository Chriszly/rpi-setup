# web - nginx

Installs the [nginx](https://nginx.org/) web server with a simple start page,
ready for your own pages or as a reverse proxy.

```bash
sudo bash setup.sh web
```

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `WEB_PORT` | `80`, or `8080` if Pi-hole already has 80 | Port nginx listens on. Re-runs move nginx when you change it. |
| `WEB_TITLE` | `Raspberry Pi` | Title of the start page. Cannot contain `<`, `>` or `&`. |

## What it installs and changes

- The `nginx` package and service, enabled and started.
- The listen port of the default site, `/etc/nginx/sites-available/default`.
- The start page `/var/www/html/index.html`. A page you put there yourself is
  never overwritten.

## Reach it

`http://<pi>` (or `http://<pi>:8080`); the task prints the address.

## Good to know

- Pi-hole and nginx can run together: whichever comes second moves to port
  8080.
- With the `firewall` task, the port is open only to `FIREWALL_ALLOW_FROM`
  (and Tailscale) when that is set.
- Turn it off with `sudo systemctl disable --now nginx`.
