# pihole - network-wide ad blocker

Installs [Pi-hole](https://pi-hole.net/) so every device that uses the Pi as
its DNS server gets ads and trackers blocked. Installs without Pi-hole's
dialogs, using the settings below.

```bash
sudo bash setup.sh pihole
```

The official installer runs as `curl https://install.pi-hole.net | bash`. The
task prints a warning first and asks no question; leave `pihole` out of the
run if you do not want the installer to run.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `PIHOLE_PASSWORD` | empty: generated | Web admin password. Empty: generated on the first install, printed once and saved. Set it later to change the password on the next run. |
| `PIHOLE_INTERFACE` | the default route's | Interface Pi-hole answers on, e.g. `eth0` or `wlan0`. Install only. |
| `PIHOLE_DNS` | `1.1.1.1,1.0.0.1` | Upstream DNS servers, comma separated (`#port` suffix allowed). Install only. |
| `PIHOLE_QUERY_LOGGING` | `yes` | Log DNS queries. Install only. |
| `PIHOLE_WEB_PORT` | `80`, or `8080` if port 80 is taken | Port of the web admin. Re-runs move it when you change it. |
| `PIHOLE_LISTEN_ALL` | empty: leave as it is | `yes`: answer DNS queries from any network, e.g. your tailnet (only safe behind a firewall). `no`: only from local subnets. Applied on every run. |
| `PIHOLE_DOCKER` | `no` | `yes` runs Pi-hole in its own Docker container instead of the installer ([below](#run-it-in-docker)). |
| `PIHOLE_IMAGE` | `pihole/pihole:latest` | Docker image for `PIHOLE_DOCKER=yes`. |

"Install only" settings are written to `/etc/pihole/pihole.toml` before the
first install; afterwards change them in Pi-hole's web UI. In Docker they
apply on every run instead.

## Reach it

- Web admin: `http://<pi>/admin` (or `http://<pi>:8080/admin` when the `web`
  task already had port 80). The task prints the address.
- Generated password: printed once and kept in
  `/var/lib/rpi-setup/secrets/pihole.env` (root only).
- To use it, set your router's DNS server (DHCP option) to the Pi's address.
  A fixed address helps: see the [network](network.md) task.

## Run it in Docker

With `PIHOLE_DOCKER=yes` the task runs Pi-hole's official image
(`PIHOLE_IMAGE`) in a container named `pihole` on the host network, so it
gets port 53 and sees the real client addresses. Docker is installed first if
it is missing, and the `curl | bash` installer is not used.

- Pi-hole's data (`/etc/pihole`) lives in `/opt/pihole/etc-pihole`.
- All `PIHOLE_*` settings are passed to the container and apply on every run;
  Pi-hole's web UI shows them read-only.
- A native Pi-hole is stopped and its lists, settings and password are copied
  over once. If the container does not stay up, the native Pi-hole is started
  again. `PIHOLE_DOCKER=no` switches back.
- Update with `sudo bash update.sh` (pulls the new image); `pihole -up` is for
  the native install only.
- The `firewall` task (DNS, admin port, DHCP), `check.sh` and the `backup`
  task recognise the container.

## Good to know

- Pi-hole and nginx (`web`) can run together: whichever comes second moves to
  port 8080.
- Pi-hole needs port 53 and does not install inside a container (CI skips it).
- Update with `sudo bash update.sh` (runs `pihole -up`). Debug with
  `pihole -d`. Remove with `pihole uninstall`.
- With the `firewall` task, DNS (53) is open to everyone and the admin UI only
  to `FIREWALL_ALLOW_FROM`; DHCP ports are opened when Pi-hole's DHCP server is on.
