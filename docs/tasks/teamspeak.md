# teamspeak - TeamSpeak 6 server

Runs a [TeamSpeak 6](https://teamspeak.com/) voice chat server from the
official Docker image (native arm64).

```bash
sudo bash setup.sh teamspeak
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS: the image exists for arm64 and amd64 only, and the task stops
on a 32-bit Pi OS. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `TEAMSPEAK_ACCEPT_LICENSE` | `yes` | You accept the TeamSpeak server license; the server does not start without it. |
| `TEAMSPEAK_VOICE_PORT` | `9987` | Voice port (UDP) on the Pi. Can be changed later; see "Voice port" below. |
| `TEAMSPEAK_FILE_PORT` | `30033` | File transfer port (TCP). |
| `TEAMSPEAK_QUERY_HTTP` | `yes` | Turn on the web query API. |
| `TEAMSPEAK_QUERY_PORT` | `10080` | Web query port (TCP). |
| `TEAMSPEAK_QUERY_ADMIN_PASSWORD` | empty: generated with `TEAMSPEAK_USAGE=yes` (and kept once generated), else TeamSpeak's own (none set) | Password of the `serveradmin` query account. Cannot contain `"`, `\` or `$`. A generated one is printed once and kept in `/var/lib/rpi-setup/secrets/teamspeak.env`. |
| `TEAMSPEAK_IMAGE` | `teamspeaksystems/teamspeak6-server:latest` | Docker image. |
| `TEAMSPEAK_USAGE` | `yes` | Log who is online and when, for the start page ([below](#who-is-online-and-when)). |
| `TEAMSPEAK_USAGE_DAYS` | `90` | Days of visits the usage log keeps (1 to 9999). |

## What it installs and changes

- `/opt/teamspeak/docker-compose.yml` (root only, it holds the query
  password) and `/opt/teamspeak/data`, owned by UID 9987: the image always
  runs as 9987.
- `/opt/teamspeak/voice-port`: the voice port the server was created with
  (see below).
- The `teamspeak` container with the voice, file and (with
  `TEAMSPEAK_QUERY_HTTP=yes`) web query ports published, restarting on its
  own.
- With `TEAMSPEAK_USAGE=yes`: the SSH query turned on inside the server (its
  port 10022 is not published), and the `teamspeak-usage` container, built on
  the Pi from `templates/teamspeak-usage` (`python:3-alpine` with the SSH
  client) into `/opt/teamspeak/usage`, its log in `/opt/teamspeak/usage/data`
  owned by its own UID.

## Reach it

- Connect the TeamSpeak 6 client to `<pi>:9987`.
- On the first start the task prints the **ServerAdmin privilege key**. It is
  shown only once; enter it in the client to become server admin. Find it
  later with `docker logs teamspeak`.
- Forward UDP 9987 and TCP 30033 on your router for friends outside your LAN.

## Voice port

TeamSpeak takes its voice port (`TSSERVER_DEFAULT_PORT`) only when it creates
its database; after that the server keeps listening on that port. So the task
uses `TEAMSPEAK_VOICE_PORT` for the port inside the container only for a new
server (empty data folder) and records it in `/opt/teamspeak/voice-port`. When
you change `TEAMSPEAK_VOICE_PORT` later, only the port on the Pi changes: it
is forwarded to the recorded port inside the container (e.g. `9988:9987/udp`).
A server set up before this file existed gets the port from its old compose
file (else 9987). If that guess is wrong, write the right port into the file
and re-run the task.

## Who is online and when

With `TEAMSPEAK_USAGE=yes` (the default) a small bot in the
`teamspeak-usage` container logs in to the server's SSH query as
`serveradmin` over the containers' own network. Query clients do not show up
in the channel tree, so users do not see it. It reads who is online,
registers for join and leave events and writes to `/opt/teamspeak/usage/data`:

- `sessions.jsonl`: one line per finished visit, with the client's unique ID,
  nickname, start and end. Visits older than `TEAMSPEAK_USAGE_DAYS` are
  dropped once a day.
- `online.json`: who is online now.
- `usage.json`: the summary the [web start page](web.md#teamspeak) shows,
  rewritten every minute, including how many were online at once over the
  last 7 days (the points where that number changes).

When the bot or the server restarts, the people still online keep their
start time; the visits of those who left in between end at the last time the
bot saw them (at most a minute or so early). The bot reconnects on its own;
`sudo docker logs teamspeak-usage` shows why it could not.

Turning it on sets a `serveradmin` password (and turns on the SSH query), so
the server is restarted once. If your server is used by people outside your
home, tell them their connection times are logged. The start page, and so
the log, is meant for your LAN only (the `firewall` task keeps it there).
`TEAMSPEAK_USAGE=no` removes the container and keeps the log (and the
generated password). While the bot cannot reach the server it stops updating
`usage.json`, so the start page hides the section after 10 minutes instead of
showing an old list. The bot and its image are rebuilt when the `teamspeak`
task runs, not by `update.sh`.

## Good to know

- Ports published by Docker bypass the `firewall` task's rules (it opens them
  anyway and says so). How to close or limit them:
  [Ports of Docker containers](firewall.md#ports-of-docker-containers).
- A newer image comes with `sudo bash update.sh`.
- Stop: `cd /opt/teamspeak && sudo docker compose down`.
