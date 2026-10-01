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
