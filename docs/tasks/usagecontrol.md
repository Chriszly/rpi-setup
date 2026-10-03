# usagecontrol - usage-control website

Runs [usage-control](https://github.com/Chriszly/usage-control), a website
that shows the Pi's CPU and memory usage, temperatures and uptime, from its
published Docker image (arm64 and amd64).

```bash
sudo bash setup.sh usagecontrol
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `USAGECONTROL_PORT` | `9393` | Port of the website on the Pi (TCP). The task stops if another program already uses it. |
| `USAGECONTROL_IMAGE` | `ghcr.io/chriszly/usage-control:main` | Docker image. `:main` follows usage-control's main branch; a release such as `:1.2.3` stays fixed. |

## What it installs and changes

- `/opt/usagecontrol/docker-compose.yml`.
- The Docker volume `usagecontrol_data` with the history, kept when the
  container is updated or recreated.
- The `usage-control` container, restarting on its own. It listens on 9393
  inside the container, published on `USAGECONTROL_PORT` over IPv4 only. It
  reads the Pi's `/proc` and `/sys` read-only, runs as a non-root user with
  no capabilities and a read-only file system, and changes nothing on the Pi.

## Reach it

Open `http://<pi>:9393` from a device on the local network. The website
answers only requests from private addresses (LAN, loopback, link-local).

## Good to know

- The Pi pulls the image without logging in, so the package on ghcr.io must
  be public (on GitHub: the package's *Package settings > Change
  visibility*). The source repository can stay private.
- A newer image comes with `sudo bash update.sh` (or *Update Pi* from your
  settings repository).
- The default port is 9393, the port usage-control listens on inside its
  container, so the address is the same with or without Docker and stays
  clear of nginx (80 or 8080). An install from before used 8080 or 8090; the
  next run of the task moves it to 9393 unless `USAGECONTROL_PORT` is set.
- Ports published by Docker bypass the `firewall` task's rules (it opens the
  port for `FIREWALL_ALLOW_FROM` anyway). How to close or limit them:
  [Ports of Docker containers](firewall.md#ports-of-docker-containers).
- Stop: `cd /opt/usagecontrol && sudo docker compose down`.
