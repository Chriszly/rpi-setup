# web - nginx

Installs the [nginx](https://nginx.org/) web server with a start page that
links every web page running on the Pi (Pi-hole, NetAlertX, usage-control and
any other container), ready for your own pages or as a reverse proxy.

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
- `/usr/local/sbin/rpi-setup-web-links` and the `rpi-setup-web-links.timer`
  that runs it every minute. It writes the list of web pages,
  `services.json`, and of Docker containers, `containers.json`, next to the
  start page ([below](#the-start-page)), and copies the TeamSpeak usage
  summary there as `teamspeak.json`.

## Reach it

`http://<pi>` (or `http://<pi>:8080`); the task prints the address.

## The start page

The page follows the light or dark setting of your browser or system on its
own. Under the title it shows the Pi's host name and LAN IP address (the
address of its default route). It shows one card per web page on the Pi, with a green dot when it
answers and a red one when it does not, and links each one on the address you
opened the page with (`raspi.local` or the IP address).

The list comes from `services.json`, which the timer rewrites every minute
(only when something changed); the page reads it again every 30 seconds. So a
service you set up later shows up without touching the page. It lists:

- Pi-hole's admin page, in its container or on the host, on the port Pi-hole
  really uses.
- The containers of rpi-setup's tasks that have a web page: NetAlertX and
  usage-control. TeamSpeak and Samba have none, and nginx is the page itself.
- Any other running container that publishes a port on the LAN which answers
  HTTP, under the container's name. Ports published on `127.0.0.1` only are
  left out.

A container can name its own card with Docker labels, which also lists a
container on the host network (it publishes no ports):

```yaml
    labels:
      rpi-setup.link.port: "8123"          # port on the Pi; required
      rpi-setup.link.name: "Home Assistant" # default: the container name
      rpi-setup.link.path: "/"              # default: /
      rpi-setup.link.description: "Smart home"
```

`rpi-setup.link: "no"` hides a container from the list. Refresh the list
right away with `sudo rpi-setup-web-links`.

### Docker containers

Below the cards the page lists every Docker container on the Pi, running or
stopped: its name, image, the ports it publishes (`host:container/protocol`,
or "host network"), and its state, with a green dot when it runs (and is
healthy), yellow while its health check starts or it restarts, and red when
it is stopped or unhealthy. The uptime counts up in the page itself.

It comes from `containers.json`, written by the same timer from one
`docker inspect` call. The file holds start and stop times rather than the
uptime, so it is only rewritten when a container starts, stops or changes.
nginx gets no access to Docker. Without Docker the section is not shown.

### TeamSpeak

With the `teamspeak` task's usage logger (`TEAMSPEAK_USAGE=yes`, the default)
the page shows who is on the TeamSpeak server right now and for how long, the
time each person was online over the last 7 days with their number of
visits and when they were last seen, and the last 15 visits with start, end
and length. The timer copies the logger's summary to `teamspeak.json`; when
the logger is off or has not written it for 10 minutes the file is removed
and the section is hidden. How the logging works:
[teamspeak usage](teamspeak.md#who-is-online-and-when).

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
- The `firewall` task, `check.sh` and the `backup` task recognise the container (the firewall opens the port from `/opt/web/conf`).

## Good to know

- `update.sh` (and the *Update Pi* workflow) re-runs this task, so the start
  page and the script behind it follow the rpi-setup version on the Pi.
- Pi-hole and nginx can run together: whichever comes second moves to port
  8080.
- With the `firewall` task, the port is open only to `FIREWALL_ALLOW_FROM`
  when that is set.
- Turn it off with `sudo systemctl disable --now nginx` (and the list with
  `sudo systemctl disable --now rpi-setup-web-links.timer`).
- With your own `index.html` the lists are still written, so your page can
  read `services.json` and `containers.json` too.
- Anyone who can open the page sees the container names, images and ports.
  The `firewall` task keeps the page to `FIREWALL_ALLOW_FROM`.
