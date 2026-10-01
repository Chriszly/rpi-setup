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
| `WEB_DOCKER` | `no` | `yes` runs nginx in its own Docker container instead of the apt package ([below](#run-it-in-docker)). |
| `WEB_IMAGE` | `nginx:stable-alpine` | Docker image for `WEB_DOCKER=yes`. |

## What it installs and changes

- The `nginx` package and service, enabled and started.
- The listen port of the default site, `/etc/nginx/sites-available/default`.
- The start page `/var/www/html/index.html`. A page you put there yourself is
  never overwritten.

## Reach it

`http://<pi>` (or `http://<pi>:8080`); the task prints the address.

## Run it in Docker

With `WEB_DOCKER=yes` the task runs nginx from `WEB_IMAGE` in a container
named `web` on the host network, instead of installing the apt package.
Docker is installed first if it is missing.

- Your pages are in `/opt/web/html`, the site config in `/opt/web/conf`.
- A native nginx is stopped (its package stays) and its `/var/www/html` is
  copied over once. Other native sites are not carried over; the task lists
  them so you can add them to `/opt/web/conf`.
- If the container does not stay up, the native nginx is started again.
  `WEB_DOCKER=no` stops the container and brings the native nginx back.
- The `firewall` task does not detect the container yet (it looks for the native nginx package), so it does not open its port for it; add e.g. `80/tcp` to `FIREWALL_EXTRA_PORTS` until it does.

## Good to know

- Pi-hole and nginx can run together: whichever comes second moves to port
  8080.
- With the `firewall` task, the port is open only to `FIREWALL_ALLOW_FROM`
  (and Tailscale) when that is set.
- Turn it off with `sudo systemctl disable --now nginx`.
