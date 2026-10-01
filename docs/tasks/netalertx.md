# netalertx - LAN device tracker

Runs [NetAlertX](https://github.com/netalertx/NetAlertX) in Docker. It scans
your LAN, lists every device it finds and can alert you when a new or a known
device appears or disappears.

```bash
sudo bash setup.sh netalertx
```

Needs Docker: the task runs the `docker` task first when Docker is missing.
If the container does not stay up, its last log lines are shown and it is
taken down again. The first scan takes 5-10 minutes.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `NETALERTX_PORT` | `20211` | Web UI port. |
| `NETALERTX_SCAN_SUBNETS` | detected from the default route | Subnets to scan, e.g. `'192.168.1.0/24 --interface=eth0'`; several separated by `;`. |
| `NETALERTX_LOGIN` | `yes` | Ask for a password before the web UI opens. `no` lets anyone on the LAN open it. |
| `NETALERTX_PASSWORD` | empty: generated | Web UI password. Empty: generated on the first install, printed once and saved; re-runs keep using it. |
| `NETALERTX_IMAGE` | `ghcr.io/netalertx/netalertx:latest` | Docker image. |

## What it installs and changes

- `/opt/netalertx/docker-compose.yml` (root only) and `/opt/netalertx/data`,
  owned by a UID/GID reserved for NetAlertX in `/var/lib/rpi-setup/uids/`.
- The `netalertx` container: host networking (it has to see the LAN),
  read-only file system, all capabilities dropped except the few it needs for
  scanning, restarts on its own.
- `/etc/sysctl.d/90-netalertx.conf` (`arp_ignore=1`, `arp_announce=2`),
  which NetAlertX recommends against ARP flux while it scans.
- The login settings in `/opt/netalertx/data/config/app.conf`.

## Reach it

- `http://<pi>:20211`. The UI also talks to NetAlertX's API on port 20212.
- Password: `NETALERTX_PASSWORD`, or the generated one in
  `/var/lib/rpi-setup/secrets/netalertx.env` (root only).
- If no subnet was detected, set it in the UI under Settings > Subnets & Rules.

## Good to know

- A changed setting recreates the container on the next run. A newer image
  comes with `sudo bash update.sh`, not with a re-run.
- Logs: `docker logs netalertx`. Stop: `cd /opt/netalertx && sudo docker compose down`.
