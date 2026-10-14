# web - nginx

Installs the [nginx](https://nginx.org/) web server with a start page that
links every web page running on the Pi (Pi-hole, NetAlertX, Den-Watcher and
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
| `WEB_UPDATES` | `yes` | `yes` looks for updates every 6 hours and lists them on the start page ([below](#updates)); `no` turns the check off and removes it. |

## What it installs and changes

- The `nginx` package and service, enabled and started.
- The listen port of the default site, `/etc/nginx/sites-available/default`.
- The start page `/var/www/html/index.html`. A page you put there yourself is
  never overwritten.
- `/usr/local/sbin/rpi-setup-web-links` and the `rpi-setup-web-links.timer`
  that runs it every minute. It writes the list of web pages,
  `services.json`, of Docker containers, `containers.json`, and of the
  rpi-setup tasks set up on the Pi, `tasks.json`, next to the start page
  ([below](#the-start-page)), and copies the TeamSpeak usage summary there as
  `teamspeak.json`.
- With `WEB_UPDATES=yes`: `/usr/local/sbin/rpi-setup-updates` and the
  `rpi-setup-updates.timer` that runs it 15 minutes after boot (or after
  the task installed it, so it does not get in the way of other tasks' package
  installs) and then every 6 hours, writing `updates.json` next to the start
  page ([below](#updates)). `update.sh` also starts it when it is done.

## Reach it

`http://<pi>` (or `http://<pi>:8080`); the task prints the address.

## The start page

The page follows the light or dark setting of your browser or system on its
own. Under the title it shows the Pi's host name and LAN IP address (the
address of its default route). It has up to three tabs: **Overview**,
**Docker** (`#docker`, while there are containers) and **TeamSpeak**
(`#teamspeak`, while there is TeamSpeak data); the tab bar only shows when
there is more than the overview.

The overview shows one card per web page on the Pi, with a green dot when it
answers and a red one when it does not, and links each one on the address you
opened the page with (`raspi.local` or the IP address).

The list comes from `services.json`, which the timer rewrites every minute
(only when something changed); the page reads it again every 30 seconds. So a
service you set up later shows up without touching the page. It lists:

- Pi-hole's admin page, in its container or on the host, on the port Pi-hole
  really uses.
- The containers of rpi-setup's tasks that have a web page: NetAlertX and
  Den-Watcher. TeamSpeak and Samba have none, and nginx is the page itself.
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

Below the cards, **Set up on this Pi** lists the rpi-setup tasks that
finished on the Pi with their description, from `tasks.json`, next to a link
to the rpi-setup repository on GitHub. The list comes from
`/var/lib/rpi-setup/tasks.done`, where `setup.sh` records every task that
finishes; a task last run with an rpi-setup version older than that record
shows up once it runs again (`update.sh` re-runs them).

### Updates

With `WEB_UPDATES=yes` (the default) the overview ends with **Updates**: what
has a newer version than the one on the Pi, with a yellow dot, next to what
is up to date (green) and what could not be checked (grey), and when the Pi
last looked. The Pi looks every 6 hours, not when the page opens, so opening
the page never waits on the network. It checks:

- **rpi-setup** itself: the commit of the checkout `setup.sh` runs from
  against the newest commit of the branch it follows, from `git ls-remote`
  as the user who owns the checkout (so nothing in the checkout changes). A
  checkout ahead of that commit counts as up to date.
- **Pi-hole** on the host: the installed and newest Core, Web and FTL
  versions from `/etc/pihole/versions`, which Pi-hole's own daily update
  check keeps. Pi-hole in its container is checked as a container.
- **EEPROM firmware** on a Raspberry Pi: `rpi-eeprom-update` without options,
  which only reports.
- Every **Docker container**: is the image it runs still the one its
  registry (Docker Hub, ghcr.io, ...) serves for that tag? One `HEAD`
  request per image, which does not count against Docker Hub's pull limit.
  Images built on the Pi, pinned by digest or private are left out or shown
  as not checked. The Docker tab marks those containers with "update
  available".
- **OS packages**: `apt-get update`, then the packages `update.sh` would
  upgrade, how many of them are security updates, and their names.

Below the list the page says how to install them: `git pull` in the
rpi-setup folder when rpi-setup has a new version, then
`sudo bash update.sh`, which also starts the check again so the list
clears. Check right away with `sudo rpi-setup-updates` (or
`sudo systemctl start rpi-setup-updates`); its log is in
`journalctl -u rpi-setup-updates`.

### Docker

The **Docker** tab lists every Docker container on the Pi, running or
stopped: its name, image, the ports it publishes (`host:container/protocol`,
or "host network"), and its state, with a green dot when it runs (and is
healthy), yellow while its health check starts or it restarts, and red when
it is stopped or unhealthy. The uptime counts up in the page itself.

It comes from `containers.json`, written by the same timer from one
`docker inspect` call. The file holds start and stop times rather than the
uptime, so it is only rewritten when a container starts, stops or changes.
nginx gets no access to Docker. Without Docker or containers the tab is not
shown.

### TeamSpeak

With the `teamspeak` task's usage logger (`TEAMSPEAK_USAGE=yes`, the default)
the **TeamSpeak** tab has everything the server reports, refreshed every minute:
the server (status, people online out of its slots, uptime, ping, packet
loss, bandwidth, data sent and received, channels, connections ever,
address, version, platform, created, welcome message); everyone online with
their server groups, channel, client version and platform, country and
state (away, muted, talking, recording, idle); the channel tree with who is
in each channel; a chart of how many people were online at the same time
over the last 7 days (with the peak; hover or touch it for the number at any
moment); a weekday-by-hour grid of the average
number of people online (in your browser's time zone); the busiest channels
over the last 7 days; the last 7 days per person; everyone in the log with
first and last seen, total time, visits, longest visit and platform; the
visitors who connected from the same IP address, grouped and named after the
nickname used last from it (the address itself is never shown), with their
other nicknames; and the last 50 visits. Server groups are a column of their own everywhere.
The timer copies the logger's summary to `teamspeak.json`; when the logger is
off or has not written it for 10 minutes the file is removed and the tab is
hidden. How the logging works:
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
  `sudo systemctl disable --now rpi-setup-web-links.timer`). The update
  check goes away with `WEB_UPDATES=no`.
- The update check reaches out to the image registries, the rpi-setup
  repository and the apt mirrors, and refreshes the apt package lists
  (`apt-get update`) every 6 hours. It installs nothing.
- With your own `index.html` the lists are still written, so your page can
  read `services.json`, `containers.json`, `tasks.json` and `updates.json` too.
- Anyone who can open the page sees the container names, images and ports.
  The `firewall` task keeps the page to `FIREWALL_ALLOW_FROM`.
