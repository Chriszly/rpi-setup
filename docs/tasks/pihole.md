# pihole - network-wide ad blocker

Installs [Pi-hole](https://pi-hole.net/) so every device that uses the Pi as
its DNS server gets ads and trackers blocked. Installs without Pi-hole's
dialogs by default, using the settings below.

```bash
sudo bash setup.sh pihole
```

The official installer runs as `curl https://install.pi-hole.net | bash`. The
task warns first and asks you to type `yes`, unless `PIHOLE_CONFIRM=yes` (set
it for an unattended run).

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `PIHOLE_CONFIRM` | empty: ask | `yes` skips the "type yes" question before the installer runs. |
| `PIHOLE_UNATTENDED` | `yes` | Install without Pi-hole's dialogs using the settings below; `no` shows the dialogs. |
| `PIHOLE_PASSWORD` | empty: generated | Web admin password. Empty: generated on the first install, printed once and saved. Set it later to change the password on the next run. |
| `PIHOLE_INTERFACE` | the default route's | Interface Pi-hole answers on, e.g. `eth0` or `wlan0`. Install only. |
| `PIHOLE_DNS` | `1.1.1.1,1.0.0.1` | Upstream DNS servers, comma separated (`#port` suffix allowed). Install only. |
| `PIHOLE_QUERY_LOGGING` | `yes` | Log DNS queries. Install only. |
| `PIHOLE_WEB_PORT` | `80`, or `8080` if port 80 is taken | Port of the web admin. Re-runs move it when you change it. |

"Install only" settings are written to `/etc/pihole/pihole.toml` before the
first install; afterwards change them in Pi-hole's web UI.

## Reach it

- Web admin: `http://<pi>/admin` (or `http://<pi>:8080/admin` when the `web`
  task already had port 80). The task prints the address.
- Generated password: printed once and kept in
  `/var/lib/rpi-setup/secrets/pihole.env` (root only).
- To use it, set your router's DNS server (DHCP option) to the Pi's address.
  A fixed address helps: see the [network](network.md) task.

## Good to know

- Pi-hole and nginx (`web`) can run together: whichever comes second moves to
  port 8080.
- Pi-hole needs port 53 and does not install inside a container (CI skips it).
- Update with `sudo bash update.sh` (runs `pihole -up`). Debug with
  `pihole -d`. Remove with `pihole uninstall`.
- The `tailscale` task turns off the tailnet DNS on this Pi automatically.
- With the `firewall` task, DNS (53) is open to everyone and the admin UI only
  to `FIREWALL_ALLOW_FROM`; DHCP ports are opened when Pi-hole's DHCP server is on.
