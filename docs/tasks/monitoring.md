# monitoring - Netdata dashboard

Installs [Netdata](https://www.netdata.cloud/), a real-time dashboard for
CPU, memory, disk, network, temperature and services.

```bash
sudo bash setup.sh monitoring
```

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `MONITORING_PORT` | `19999` | Dashboard port. |
| `MONITORING_BIND` | `0.0.0.0` | Address to listen on: `0.0.0.0` = whole LAN, `127.0.0.1` = this Pi only. |
| `MONITORING_TELEMETRY` | `no` | `yes` sends Netdata's anonymous usage statistics. |
| `MONITORING_DOCKER` | `no` | `yes` runs Netdata in its own Docker container instead of the apt package ([below](#run-it-in-docker)). |
| `MONITORING_IMAGE` | `netdata/netdata:stable` | Docker image for `MONITORING_DOCKER=yes`. |

## What it installs and changes

- The `netdata` package. On Trixie, where Debian no longer ships it, the task
  adds Netdata's own signed apt repository first
  (`/etc/apt/sources.list.d/netdata.list`).
- `/etc/netdata/netdata.conf`: listen address and port. Debian's package
  listens on 127.0.0.1 only; the task opens it to the LAN by default.
- `/etc/netdata/.opt-out-from-anonymous-statistics` while telemetry is off.
- The `netdata` service, enabled and started.

## Reach it

`http://<pi>:19999`, no login. Anyone who can reach the port can see it: use
`MONITORING_BIND=127.0.0.1` with an SSH tunnel, or the `firewall` task with
`FIREWALL_ALLOW_FROM`, to limit that.

Turn it off with `sudo systemctl disable --now netdata`.

## Run it in Docker

With `MONITORING_DOCKER=yes` the task runs Netdata's official image
(`MONITORING_IMAGE`) in a container named `netdata`, set up as Netdata
documents it: host network and process namespace, the host's `/proc`, `/sys`
and `/` mounted read-only. Docker is installed first if it is missing.

- Config, database and cache live in `/opt/monitoring`.
- A native netdata is stopped (its package stays); its metric history is not
  carried over. If the container does not stay up, the native netdata is
  started again. `MONITORING_DOCKER=no` switches back.
- The `firewall` task does not detect the container yet (it looks for the native netdata package), so it does not open the dashboard port for it; add `19999/tcp` to `FIREWALL_EXTRA_PORTS` until it does.
