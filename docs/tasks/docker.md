# docker - Docker Engine and Compose

Installs Docker Engine with the buildx and Compose plugins from Docker's own
apt repository and limits container logs to 3 files of 10 MB each, so logs
cannot fill the SD card.

```bash
sudo bash setup.sh docker
```

`netalertx` and `teamspeak` need Docker. When you pick one of them and Docker
is not installed yet, `setup.sh` adds the `docker` task automatically and runs
it first.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `DOCKER_ADD_USER` | `yes` | Add the user who ran `sudo` to the `docker` group, so `docker` works without `sudo` (after logging in again). |

## What it installs and changes

- Docker's apt repository (`/etc/apt/sources.list.d/docker.list`, key in
  `/etc/apt/keyrings/docker.gpg`) and the packages `docker-ce docker-ce-cli
  containerd.io docker-buildx-plugin docker-compose-plugin`.
- `/etc/docker/daemon.json` with the log rotation. A `daemon.json` you edited
  yourself is left alone (the task warns and skips the log settings).
- The `docker` service is enabled and started.

If Docker is already installed from another source without Compose v2, the
task only adds the Compose plugin.

## Good to know

- Log out and back in (reconnect SSH) after the first run to use `docker`
  without `sudo`.
- rpi-setup's containers live in `/opt/<task>/` (a `docker-compose.yml` plus
  a `data/` folder). `sudo bash update.sh` pulls new images and recreates the
  containers that changed; re-running a task does not. Switching a task back
  to native (`<TASK>_DOCKER=no`) renames its file to
  `docker-compose.yml.disabled`, so `update.sh` leaves it alone; the data stays.
- Turn Docker off with `sudo systemctl disable --now docker docker.socket`.
