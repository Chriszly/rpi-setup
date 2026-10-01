# teamspeak - TeamSpeak 6 server

Runs a [TeamSpeak 6](https://teamspeak.com/) voice chat server from the
official Docker image (native arm64).

```bash
sudo bash setup.sh teamspeak
```

Needs `docker` (added automatically when missing) and a **64-bit** OS: the
image exists for arm64 and amd64 only, and the task stops on a 32-bit Pi OS.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `TEAMSPEAK_ACCEPT_LICENSE` | `yes` | You accept the TeamSpeak server license; the server does not start without it. |
| `TEAMSPEAK_VOICE_PORT` | `9987` | Voice port (UDP). Only applies when the server is first created (empty data folder). |
| `TEAMSPEAK_FILE_PORT` | `30033` | File transfer port (TCP). |
| `TEAMSPEAK_QUERY_HTTP` | `yes` | Turn on the web query API. |
| `TEAMSPEAK_QUERY_PORT` | `10080` | Web query port (TCP). |
| `TEAMSPEAK_QUERY_ADMIN_PASSWORD` | empty: TeamSpeak's own (none set) | Password of the `serveradmin` query account. Cannot contain `"`, `\` or `$`. |
| `TEAMSPEAK_IMAGE` | `teamspeaksystems/teamspeak6-server:latest` | Docker image. |

## What it installs and changes

- `/opt/teamspeak/docker-compose.yml` (root only, it holds the query
  password) and `/opt/teamspeak/data`, owned by UID 9987: the image always
  runs as 9987.
- The `teamspeak` container with the three ports published, restarting on
  its own.

## Reach it

- Connect the TeamSpeak 6 client to `<pi>:9987`.
- On the first start the task prints the **ServerAdmin privilege key**. It is
  shown only once; enter it in the client to become server admin. Find it
  later with `docker logs teamspeak`.
- Forward UDP 9987 and TCP 30033 on your router for friends outside your LAN.

## Good to know

- Ports published by Docker bypass the `firewall` task's rules (it opens them
  anyway and says so).
- A newer image comes with `sudo bash update.sh`.
- Stop: `cd /opt/teamspeak && sudo docker compose down`.
