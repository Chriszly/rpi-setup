# denwatcher - Den-Watcher website

Runs [Den-Watcher](https://github.com/Chriszly/den-watcher), a website
that shows the Pi's CPU and memory usage, temperatures and uptime, from its
published Docker image (arm64 and amd64). It was the `usagecontrol` task
before Den-Watcher's rename; see [Renamed from usagecontrol](#renamed-from-usagecontrol).

```bash
sudo bash setup.sh denwatcher
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `DENWATCHER_PORT` | `9393` | Port of the website on the Pi (TCP). The task stops if another program already uses it. |
| `DENWATCHER_IMAGE` | `ghcr.io/chriszly/den-watcher:main` | Docker image. `:main` follows Den-Watcher's main branch; a release such as `:1.2.3` stays fixed. |
| `DENWATCHER_ROUTERS` | empty | Routers to show as devices of their own (Den-Watcher 2.0 and later), as `name=protocol:address`, comma-separated, such as `Router=upnp:192.168.1.1`. The protocol is `upnp` (no login), `asus`, `fritzbox` or `snmpv3` (with the user before the address, such as `Box=fritzbox:user@192.168.178.1`) or `snmp` (v2c). Becomes Den-Watcher's `HUB_ROUTERS`. |
| `DENWATCHER_CONTAINERS` | `yes` | Show the CPU and memory of every other Docker container on the Pi, with Den-Watcher's containers add-on (see below). `no` leaves it out. |
| `DENWATCHER_ROUTER_PASSWORD` | empty: the one kept from an earlier run | Passwords of the routers that log in, and an SNMP community other than `public`, as `name=password`, comma-separated for several; a password cannot hold a comma. Kept in `/var/lib/rpi-setup/secrets/denwatcher.env`, so it needs to be given only once (see below). |

## What it installs and changes

- `/opt/denwatcher/docker-compose.yml`.
- `/opt/denwatcher/router-secrets/router-passwords` with the router
  passwords, one `name=password` per line, readable only by root and the
  container's user (65532); removed when there are none. A changed file
  restarts the container.
- The Docker volume `denwatcher_data` with the history, kept when the
  container is updated or recreated.
- The `den-watcher` container, restarting on its own. It listens on 9393
  inside the container, published on `DENWATCHER_PORT` over IPv4 only. It
  reads the Pi's `/proc` and `/sys` read-only, runs as a non-root user with
  no capabilities and a read-only file system, and changes nothing on the Pi.
  Its labels give it a card with a description on the `web` task's start
  page, also when only this task was run since the page was set up.
- With `DENWATCHER_CONTAINERS=yes`, the `den-watcher-containers`
  container (Den-Watcher's containers add-on, from the same image) and the
  in-memory Docker volume `denwatcher_addons` it hands its values over in.
  It finds every running container on its own, also ones started later, and
  shows each by name with its CPU and memory and their history.

## Containers on the page

The containers add-on reads each container's CPU and memory from the kernel's
cgroups (`/sys/fs/cgroup`) and their names from the `containers` folder in
Docker's data folder (as `docker info` shows it under *Docker Root Dir*,
usually `/var/lib/docker`), both mounted read-only. It never gets the Docker
socket: whoever can talk to that socket can start a container with the whole
Pi mounted, so it is as good as root on the Pi. Instead the add-on runs as
root inside its container only because the container names are in files only
root may read, but without any capability, without network and with a
read-only file system, so it can only read.

Raspberry Pi OS's kernel counts no memory per container unless
`cgroup_enable=memory` is added to the line in `/boot/firmware/cmdline.txt`
(and the Pi rebooted); without it the page shows only the CPU of each
container, and the task says so.

## Reach it

Open `http://<pi>:9393` from a device on the local network. The website
answers only requests from private addresses (LAN, loopback, link-local).

## Good to know

- The Pi pulls the image without logging in, so the package on ghcr.io must
  be public (on GitHub: the package's *Package settings > Change
  visibility*). The source repository can stay private.
- A newer image comes with `sudo bash update.sh` (or *Update Pi* from your
  settings repository).
- The default port is 9393, the port Den-Watcher listens on inside its
  container, so the address is the same with or without Docker and stays
  clear of nginx (80 or 8080). An install from before used 8080 or 8090; the
  next run of the task moves it to 9393 unless `DENWATCHER_PORT` is set.
- Ports published by Docker bypass the `firewall` task's rules (it opens the
  port for `FIREWALL_ALLOW_FROM` anyway). How to close or limit them:
  [Ports of Docker containers](firewall.md#ports-of-docker-containers).
- A router's password does not belong in the settings file, which may be in
  git: set it once on the Pi with
  `sudo DENWATCHER_ROUTER_PASSWORD='Box=secret' bash setup.sh denwatcher`.
  Later runs, also from *Update Pi*, keep it until a new one is given. A
  `upnp` router needs none.
- Stop: `cd /opt/denwatcher && sudo docker compose down`.

## Renamed from usagecontrol

Before Den-Watcher's rename the task was called `usagecontrol`, with
`USAGECONTROL_*` settings, the folder `/opt/usagecontrol` and the volume
`usagecontrol_data`. On a Pi set up that way, the first run of `denwatcher`
(from *Update Pi* once the settings repository lists `denwatcher`) moves it
over once: it stops the old containers, copies the history into
`denwatcher_data`, keeps the router passwords and removes `/opt/usagecontrol`.
The port stays. The old volume is kept as a backup; once the page shows the
history, remove it with `sudo docker volume rm usagecontrol_data`.

`USAGECONTROL_*` lines in the settings file still work, with a warning per
line; rename them to `DENWATCHER_*`. The old image name
`ghcr.io/chriszly/usage-control` stops the task: set `DENWATCHER_IMAGE` to
`ghcr.io/chriszly/den-watcher` with the same tag (2.0.8a or later).
