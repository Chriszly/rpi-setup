#!/usr/bin/env python3
"""Log who is online on the TeamSpeak server, and when (tasks/teamspeak.sh).

Runs in the teamspeak-usage container next to the server. It logs in to the
server's SSH query as serveradmin (query clients are hidden from users),
reads who is online, registers for join and leave events and writes, in
$USAGE_DATA (default /data):

  sessions.jsonl  one line per finished visit: uid, nick, start, end (epoch)
                  and the names of the client's server groups
  online.json     who is online now, and when that was last confirmed
  stats.json      minutes spent per channel per day (last 7 days)
  usage.json      the summary the start page shows (copied there by the web
                  task's rpi-setup-web-links timer)

Once a minute it also reads the server info, the channels and the details of
each client online (channel, client version and platform, country, away and
muted state, idle time) for the page's TeamSpeak tab.

Visits older than $USAGE_DAYS days are dropped. When the connection or the
bot stops, the people online stay recorded; on the next connect the ones still
there keep their start time and the others' visits end at the last check.

Run with --summary to print usage.json from the files without connecting.
"""
import json
import os
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time

DATA = os.environ.get("USAGE_DATA", "/data")
HOST = os.environ.get("TS_HOST", "teamspeak")
PORT = os.environ.get("TS_QUERY_SSH_PORT", "10022")
SERVER_ID = os.environ.get("TS_SERVER_ID", "1")
DAYS = max(1, int(os.environ.get("USAGE_DAYS", "90") or 90))
TICK = 60          # keepalive and usage.json refresh, seconds
SILENT = 3 * TICK  # reconnect when the server said nothing for this long
WEEK = 7 * 86400
RECENT = 50

# serverinfo fields the page shows, with the names usage.json gives them.
# Numbers are turned into numbers; the rest stay text.
SERVER_FIELDS = {
    "virtualserver_name": "name", "virtualserver_status": "status",
    "virtualserver_platform": "platform", "virtualserver_version": "version",
    "virtualserver_port": "port", "virtualserver_maxclients": "max_clients",
    "virtualserver_reserved_slots": "reserved_slots",
    "virtualserver_clientsonline": "clients_online",
    "virtualserver_queryclientsonline": "query_clients_online",
    "virtualserver_channelsonline": "channels", "virtualserver_uptime": "uptime",
    "virtualserver_created": "created", "virtualserver_total_ping": "ping",
    "virtualserver_total_packetloss_total": "packet_loss",
    "connection_bandwidth_sent_last_minute_total": "bandwidth_sent",
    "connection_bandwidth_received_last_minute_total": "bandwidth_received",
    "connection_bytes_sent_total": "bytes_sent",
    "connection_bytes_received_total": "bytes_received",
    "virtualserver_client_connections": "client_connections",
    "virtualserver_welcomemessage": "welcome",
}

ESCAPES = {"\\": "\\", "/": "/", "s": " ", "p": "|", "a": "\a", "b": "\b",
           "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def unescape(s):
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(1)), s)


def parse_records(text):
    """'a=1 b=x\\sy|a=2' -> [{'a': '1', 'b': 'x y'}, {'a': '2'}]"""
    out = []
    for part in text.split("|"):
        rec = {}
        for tok in part.split():
            key, _, val = tok.partition("=")
            rec[key] = unescape(val)
        out.append(rec)
    return out


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def path(name):
    return os.path.join(DATA, name)


def write_json(name, obj):
    tmp = path(name + ".new")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path(name))


def read_json(name, default):
    try:
        with open(path(name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def number(v):
    """v as an int or float if it is one, else unchanged."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return v
    return int(f) if f == int(f) else round(f, 4)


def flag(rec, key):
    return rec.get(key, "0") == "1"


def client_details(rec, channel_names, now):
    """What the page shows of an online client, from clientlist -uid -groups
    -away -voice -times -info -country."""
    version = rec.get("client_version", "")
    idle = number(rec.get("client_idle_time", 0))
    return {
        "cid": rec.get("cid", ""),
        "channel": channel_names.get(rec.get("cid", ""), ""),
        "platform": rec.get("client_platform", ""),
        "version": version.split(" [")[0],
        "country": rec.get("client_country", ""),
        "away": flag(rec, "client_away"),
        "away_message": rec.get("client_away_message", ""),
        "input_muted": flag(rec, "client_input_muted"),
        "output_muted": flag(rec, "client_output_muted"),
        "input_off": "client_input_hardware" in rec and not flag(rec, "client_input_hardware"),
        "output_off": "client_output_hardware" in rec and not flag(rec, "client_output_hardware"),
        "talking": flag(rec, "client_flag_talking"),
        "recording": flag(rec, "client_is_recording"),
        "priority_speaker": flag(rec, "client_is_priority_speaker"),
        "idle_seconds": int(idle) // 1000 if isinstance(idle, (int, float)) else 0,
        "created": int(number(rec.get("client_created", 0)) or 0)
        if isinstance(number(rec.get("client_created", 0)), (int, float)) else 0,
    }


def channel_tree(channels):
    """Channels in the order the client shows them, each with its depth:
    children follow their parent, siblings by channel_order (the cid of the
    channel above, 0 for the first)."""
    kids = {}
    for c in channels:
        kids.setdefault(c["pid"], []).append(c)
    out = []

    def walk(pid, depth):
        left = kids.get(pid, [])
        prev = "0"
        while left:
            nxt = next((c for c in left if c["order"] == prev), left[0])
            left = [c for c in left if c is not nxt]
            out.append(dict(nxt, depth=depth))
            walk(nxt["cid"], depth + 1)
            prev = nxt["cid"]
    walk("0", 0)
    seen = {c["cid"] for c in out}
    out += [dict(c, depth=0) for c in channels if c["cid"] not in seen]
    return out


def client_ip(rec):
    """The client's IP from clientlist -ip or a join event; an empty
    connection_client_ip (the server does not tell) gives ''."""
    return rec.get("connection_client_ip", "").strip()


def group_ids(rec):
    """The server group IDs of a client record ('client_servergroups=6,8')."""
    return [g for g in rec.get("client_servergroups", "").split(",") if g]


def read_sessions():
    sessions = []
    try:
        with open(path("sessions.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    s = json.loads(line)
                    sessions.append({"uid": str(s["uid"]), "nick": str(s["nick"]),
                                     "start": int(s["start"]), "end": int(s["end"]),
                                     "groups": [str(g) for g in s.get("groups") or []],
                                     "platform": str(s.get("platform") or ""),
                                     "created": int(s.get("created") or 0),
                                     "ip": str(s.get("ip") or "")})
                except (ValueError, KeyError, TypeError):
                    continue
    except OSError:
        pass
    return sessions


class Usage:
    """Who is online (by query client id) and the finished visits."""

    def __init__(self):
        state = read_json("online.json", {})
        self.checked = int(state.get("checked") or 0)
        self.online = {}
        for clid, c in (state.get("clients") or {}).items():
            try:
                self.online[str(clid)] = {"uid": str(c["uid"]), "nick": str(c["nick"]),
                                          "since": int(c["since"]),
                                          "groups": [str(g) for g in c.get("groups") or []],
                                          "ip": str(c.get("ip") or "")}
            except (KeyError, TypeError, ValueError):
                continue
        self.group_names = {str(k): str(v) for k, v in (state.get("group_names") or {}).items()}
        self.server = {}
        self.channels = []
        self.details = {}
        stats = read_json("stats.json", {})
        self.channel_minutes = stats.get("channel_minutes") or {}
        self.sampled = 0
        self.connected = False
        self.pruned = 0

    def names(self, ids):
        """Names of server group IDs, in the server's order; unknown IDs are
        left out."""
        return [self.group_names[g] for g in ids if g in self.group_names]

    def end_visit(self, c, end):
        line = json.dumps({"uid": c["uid"], "nick": c["nick"], "start": c["since"],
                           "end": max(int(end), c["since"]), "groups": self.names(c["groups"]),
                           "platform": c.get("platform", ""), "created": c.get("created", 0),
                           "ip": c.get("ip", "")},
                          ensure_ascii=False)
        with open(path("sessions.jsonl"), "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def save(self, now):
        """Record who is online. usage.json is only rewritten while connected:
        without a connection the list is unconfirmed, so the file goes stale
        and the start page hides it after 10 minutes."""
        if self.connected:
            self.checked = int(now)
        write_json("online.json", {"checked": self.checked, "clients": self.online,
                                   "group_names": self.group_names})
        if self.connected:
            write_json("stats.json", {"channel_minutes": self.channel_minutes})
            write_json("usage.json", summary(self.online, read_sessions(), now, self.names,
                                             self.live()))

    def live(self):
        return {"server": self.server, "channels": self.channels, "details": self.details,
                "channel_minutes": self.channel_minutes}

    def set_live(self, server, channels, clients, now):
        """Take the server info, the channels and the client details read
        once a minute, and count each client's minute in its channel."""
        info = server[0] if server else {}
        self.server = {name: number(info[key]) for key, name in SERVER_FIELDS.items() if key in info}
        self.channels = [{"cid": c.get("cid", ""), "pid": c.get("pid", "0"),
                          "order": c.get("channel_order", "0"), "name": c.get("channel_name", ""),
                          "topic": c.get("channel_topic", "")} for c in channels if c.get("cid")]
        names = {c["cid"]: c["name"] for c in self.channels}
        self.details = {}
        for rec in clients:
            c = self.online.get(rec.get("clid", ""))
            if c is None or rec.get("client_type", "0") != "0":
                continue
            d = client_details(rec, names, now)
            self.details[rec["clid"]] = d
            if "client_servergroups" in rec:
                c["groups"] = group_ids(rec)
            if rec.get("client_nickname"):
                c["nick"] = rec["client_nickname"]
            c["platform"] = d["platform"]
            c["ip"] = client_ip(rec) or c.get("ip", "")
            if d["created"]:
                c["created"] = d["created"]
        # Channel minutes: the time since the last sample (at most two ticks,
        # so a gap in the connection is not counted) for each client.
        step = min(now - self.sampled, 2 * TICK) / 60 if self.sampled else 0
        self.sampled = now
        if step > 0:
            day = time.strftime("%Y-%m-%d", time.gmtime(now))
            counts = self.channel_minutes.setdefault(day, {})
            for d in self.details.values():
                if d["channel"]:
                    counts[d["channel"]] = round(counts.get(d["channel"], 0) + step, 2)
        keep = {time.strftime("%Y-%m-%d", time.gmtime(now - i * 86400)) for i in range(7)}
        self.channel_minutes = {k: v for k, v in self.channel_minutes.items() if k in keep}

    def set_groups(self, groups):
        """Record the server group names from servergrouplist: regular groups
        only (type 1), not templates or query groups."""
        self.group_names = {g["sgid"]: g.get("name", "") for g in groups
                            if g.get("sgid") and g.get("type", "1") == "1"}


    def reconcile(self, clients, now):
        """Start over from a client list read right after connecting."""
        before = {}
        for c in self.online.values():
            before.setdefault(c["uid"], []).append(c)
        self.online = {}
        for rec in clients:
            if rec.get("client_type", "0") != "0" or not rec.get("clid"):
                continue
            uid = rec.get("client_unique_identifier", "")
            nick = rec.get("client_nickname", "")
            kept = before.get(uid) or []
            since = kept.pop(0)["since"] if kept else int(now)
            self.online[rec["clid"]] = {"uid": uid, "nick": nick, "since": since,
                                        "groups": group_ids(rec), "ip": client_ip(rec)}
        gone_at = self.checked or int(now)
        for left in before.values():
            for c in left:
                self.end_visit(c, gone_at)
        self.connected = True
        self.save(now)

    def event(self, name, recs, now):
        if not self.connected:
            return
        changed = False
        if name == "notifycliententerview":
            for rec in recs:
                if rec.get("client_type", "0") != "0" or not rec.get("clid"):
                    continue
                self.online[rec["clid"]] = {"uid": rec.get("client_unique_identifier", ""),
                                            "nick": rec.get("client_nickname", ""),
                                            "since": int(now), "groups": group_ids(rec),
                                            "ip": client_ip(rec)}
                changed = True
        elif name == "notifyclientleftview":
            for rec in recs:
                c = self.online.pop(rec.get("clid", ""), None)
                if c:
                    self.end_visit(c, now)
                    changed = True
        if changed:
            self.save(now)

    def prune(self, now):
        """Drop visits older than DAYS days, at most once a day."""
        if now - self.pruned < 86400:
            return
        self.pruned = now
        cut = now - DAYS * 86400
        sessions = read_sessions()
        keep = [s for s in sessions if s["end"] >= cut]
        if len(keep) == len(sessions):
            return
        tmp = path("sessions.jsonl.new")
        with open(tmp, "w", encoding="utf-8") as f:
            for s in keep:
                f.write(json.dumps(s, ensure_ascii=False) + "\n")
        os.replace(tmp, path("sessions.jsonl"))


def concurrent(online, sessions, now):
    """How many were online at once over the last 7 days, as [time, count]
    points where the count changes (a step line), from 7 days ago to now."""
    now = int(now)
    week = now - WEEK
    spans = [(s["start"], s["end"]) for s in sessions if s["end"] > week]
    spans += [(c["since"], now) for c in online.values()]
    count = sum(1 for start, end in spans if start <= week < end)
    changes = {}
    for start, end in spans:
        if start > week:
            changes[start] = changes.get(start, 0) + 1
        if end < now and end > week:
            changes[end] = changes.get(end, 0) - 1
    points = [[week, count]]
    for t in sorted(changes):
        if not changes[t]:
            continue
        count += changes[t]
        points.append([t, count])
    points.append([now, count])
    return points


def heatmap(online, sessions, now):
    """Average number of people online per weekday and hour (UTC, Monday 0:00
    first, 168 values) over the time the log covers."""
    spans = [(s["start"], s["end"]) for s in sessions]
    spans += [(c["since"], now) for c in online.values()]
    cells = [0.0] * 168
    if not spans:
        return cells
    first = max(min(start for start, _ in spans), now - DAYS * 86400)
    weeks = max((now - first) / WEEK, 1 / 7)
    for start, end in spans:
        t = max(start, first)
        while t < end:
            nxt = min(end, (int(t) // 3600 + 1) * 3600)
            g = time.gmtime(t)
            cells[g.tm_wday * 24 + g.tm_hour] += nxt - t
            t = nxt
    return [round(c / 3600 / weeks, 3) for c in cells]


def people_rows(online, sessions, now, names):
    """Everyone in the log: first and last seen, total time, visits, longest
    visit, latest server groups and platform."""
    out = {}

    def entry(uid, nick):
        return out.setdefault(uid or nick, {"nick": nick, "first_seen": None, "last_seen": 0,
                                             "total_seconds": 0, "visits": 0,
                                             "longest_seconds": 0, "groups": [],
                                             "platform": "", "online": False})

    def add(p, nick, start, end, groups, platform, created):
        first = min(x for x in (start, created or start) if x)
        p["first_seen"] = first if p["first_seen"] is None else min(p["first_seen"], first)
        if end >= p["last_seen"]:
            p["nick"], p["last_seen"], p["groups"] = nick, end, groups
            p["platform"] = platform or p["platform"]
        p["total_seconds"] += end - start
        p["visits"] += 1
        p["longest_seconds"] = max(p["longest_seconds"], end - start)

    for s in sessions:
        add(entry(s["uid"], s["nick"]), s["nick"], s["start"], s["end"], s.get("groups") or [],
            s.get("platform", ""), s.get("created", 0))
    for c in online.values():
        p = entry(c["uid"], c["nick"])
        add(p, c["nick"], c["since"], int(now), names(c.get("groups") or []),
            c.get("platform", ""), c.get("created", 0))
        p["online"] = True
    rows = [dict(p, first_seen=iso(p["first_seen"] or now), last_seen=iso(p["last_seen"]),
                 total_seconds=int(p["total_seconds"]), longest_seconds=int(p["longest_seconds"]))
            for p in out.values()]
    rows.sort(key=lambda p: (not p["online"], -p["total_seconds"], p["nick"].lower()))
    return rows


def ip_groups(online, sessions, now):
    """Visits grouped by the client's IP, to see which nicknames and
    identities come from the same connection. A group is named after the
    nickname used last from it; the IP itself is never shown. Groups with
    several identities come first."""
    out = {}
    for uid, nick, end, ip, on in ([(s["uid"], s["nick"], s["end"], s.get("ip", ""), False)
                                    for s in sessions] +
                                   [(c["uid"], c["nick"], int(now), c.get("ip", ""), True)
                                    for c in online.values()]):
        if not ip:
            continue
        g = out.setdefault(ip, {"people": {}, "visits": 0, "last": 0, "online": False})
        g["visits"] += 1
        g["online"] = g["online"] or on
        g["last"] = max(g["last"], end)
        p = g["people"].setdefault(uid or nick, {"nick": nick, "last": 0, "online": False})
        if end >= p["last"]:
            p["nick"], p["last"] = nick, end
        p["online"] = p["online"] or on
    rows = []
    for g in out.values():
        nicks = []
        for p in sorted(g["people"].values(), key=lambda p: (not p["online"], -p["last"])):
            if p["nick"] not in nicks:
                nicks.append(p["nick"])
        rows.append({"nick": nicks[0], "others": nicks[1:], "identities": len(g["people"]),
                     "visits": g["visits"], "last": g["last"], "online": g["online"]})
    rows.sort(key=lambda r: (-r["identities"], not r["online"], -r["last"], r["nick"].lower()))
    return [{k: v for k, v in dict(r, last_seen=iso(r["last"])).items() if k != "last"} for r in rows]


def live_summary(online, live, names):
    """The server, its channels with who is in them, and the details of each
    client online, for the TeamSpeak tab."""
    details = live.get("details") or {}
    clients = []
    for clid, c in online.items():
        d = details.get(clid) or {}
        clients.append(dict(d, nick=c["nick"], since=iso(c["since"]),
                            groups=names(c.get("groups") or [])))
    clients.sort(key=lambda c: c["since"])
    channels = []
    for ch in channel_tree(live.get("channels") or []):
        channels.append({"name": ch["name"], "topic": ch["topic"], "depth": ch["depth"],
                         "clients": [c["nick"] for c in clients if c.get("cid") == ch["cid"]]})
    totals = {}
    for day in (live.get("channel_minutes") or {}).values():
        for name, minutes in day.items():
            totals[name] = totals.get(name, 0) + minutes
    busy = sorted(({"name": k, "minutes": round(v)} for k, v in totals.items() if v >= 1),
                  key=lambda c: -c["minutes"])
    for c in clients:
        c.pop("cid", None)
    return {"server": live.get("server") or {}, "channels": channels, "clients": clients,
            "busy_channels": busy}


def summary(online, sessions, now, names=lambda ids: [], live=None):
    """The start page's view: who is online, the last visits, per person the
    time online over the last 7 days and their server groups (as of their
    latest visit), and how many were online at once; for the TeamSpeak tab
    also everyone in the log, the busy hours and, from live (Usage.live()),
    the server, channels and client details. names turns an online client's
    group IDs into names."""
    week = now - WEEK
    people = {}

    def person(uid, nick, last, groups):
        p = people.setdefault(uid or nick, {"nick": nick, "last": 0, "week": 0, "visits": 0,
                                            "online": False, "groups": []})
        if last >= p["last"]:
            p["nick"], p["last"], p["groups"] = nick, last, groups
        return p

    for s in sessions:
        p = person(s["uid"], s["nick"], s["end"], s.get("groups") or [])
        if s["end"] >= week:
            p["week"] += s["end"] - max(s["start"], week)
            p["visits"] += 1
    for c in online.values():
        p = person(c["uid"], c["nick"], now, names(c.get("groups") or []))
        p["week"] += now - max(c["since"], week)
        p["visits"] += 1
        p["online"] = True
    users = [{"nick": p["nick"], "online": p["online"], "last_seen": iso(p["last"]),
              "week_seconds": int(p["week"]), "week_visits": p["visits"], "groups": p["groups"]}
             for p in people.values() if p["visits"] or p["online"]]
    users.sort(key=lambda u: (not u["online"], -u["week_seconds"], u["nick"].lower()))
    recent = sorted(sessions, key=lambda s: s["end"], reverse=True)[:RECENT]
    return {
        "updated": iso(now),
        "days": DAYS,
        "online": sorted(({"nick": c["nick"], "since": iso(c["since"])} for c in online.values()),
                         key=lambda c: c["since"]),
        "recent": [{"nick": s["nick"], "start": iso(s["start"]), "end": iso(s["end"]),
                    "groups": s.get("groups") or []} for s in recent],
        "users": users,
        "concurrent": concurrent(online, sessions, now),
        "people": people_rows(online, sessions, now, names),
        "heatmap": heatmap(online, sessions, now),
        "connections": ip_groups(online, sessions, now),
        **live_summary(online, live or {}, names),
    }


class Query:
    """One SSH query connection: send commands, read replies and events."""

    def __init__(self, on_event):
        cmd = os.environ.get("TS_SSH_CMD")
        if cmd:
            argv = shlex.split(cmd)
        else:
            argv = ["ssh", "-T", "-p", PORT,
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
                    "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
                    "-o", "ServerAliveInterval=60", "-o", "ServerAliveCountMax=3",
                    "serveradmin@" + HOST]
        env = dict(os.environ, SSH_ASKPASS=os.path.abspath(__file__),
                   SSH_ASKPASS_REQUIRE="force", TSUSAGE_ASKPASS="1", DISPLAY=":0")
        self.on_event = on_event
        self.lines = queue.Queue()
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.proc.stdout:
            self.lines.put(raw.decode("utf-8", "replace").strip("\r\n"))
        self.lines.put(None)

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def send(self, command):
        self.proc.stdin.write((command + "\n").encode())
        self.proc.stdin.flush()

    def line(self, timeout):
        """The next line (events go to on_event first); None at the end."""
        while True:
            line = self.lines.get(timeout=timeout)
            if line is None:
                raise ConnectionError("the query connection closed")
            # Values never hold a blank (it is sent as \s), so an event
            # name is a word of its own; text before it would be a prompt.
            m = re.search(r"(?:^|\s)(notify[a-z]+)(?:\s|$)", line)
            if m:
                self.on_event(m.group(1), parse_records(line[m.end():]))
                continue
            return line

    def command(self, command, timeout=15):
        """Send command; its data records, or ConnectionError on an error."""
        self.send(command)
        data = []
        deadline = time.time() + timeout
        while True:
            line = self.line(max(0.1, deadline - time.time()))
            at = line.find("error id=")
            if at < 0:
                if "=" in line:
                    data.extend(parse_records(line))
                continue
            err = parse_records(line[at + len("error "):])[0]
            if err.get("id") != "0":
                raise ConnectionError("%s: %s" % (command.split()[0], err.get("msg", line)))
            return data


def run(usage):
    q = Query(lambda name, recs: usage.event(name, recs, time.time()))
    try:
        # Events before the client list are in it already, so they are
        # ignored until reconcile; the ones after it are not.
        q.command("use " + SERVER_ID)
        q.command("servernotifyregister event=server")
        usage.set_groups(q.command("servergrouplist"))
        clients = q.command("clientlist -uid -groups -ip")
        usage.reconcile(clients, time.time())
        log("Connected; %d online" % len(usage.online))
        heard = time.time()
        while True:
            usage.prune(time.time())
            # Group names and members, channels and the clients' state change
            # at any time; once a minute is soon enough for the page.
            usage.set_groups(q.command("servergrouplist"))
            usage.set_live(q.command("serverinfo"), q.command("channellist -topic"),
                           q.command("clientlist -uid -groups -ip -away -voice -times -info -country"),
                           time.time())
            usage.save(time.time())
            q.send("version")
            end = time.time() + TICK
            while time.time() < end:
                try:
                    q.line(max(0.01, end - time.time()))
                    heard = time.time()
                except queue.Empty:
                    break
            if time.time() - heard > SILENT:
                raise ConnectionError("no answer from the server for %d s" % SILENT)
    finally:
        usage.connected = False
        q.close()


def main():
    if os.environ.get("TSUSAGE_ASKPASS"):
        print(os.environ.get("TS_QUERY_PASSWORD", ""))
        return
    if sys.argv[1:] == ["--summary"]:
        usage = Usage()
        json.dump(summary(usage.online, read_sessions(), time.time(), usage.names, usage.live()),
                  sys.stdout,
                  ensure_ascii=False, separators=(",", ":"))
        print()
        return
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    os.makedirs(DATA, exist_ok=True)
    usage = Usage()
    wait = 5
    while True:
        started = time.time()
        try:
            run(usage)
        except (ConnectionError, OSError, queue.Empty) as e:
            log("TeamSpeak query: %s; trying again in %d s" % (e, wait))
        try:
            usage.save(time.time())
        except OSError as e:
            log("Cannot write to %s: %s" % (DATA, e))
        if time.time() - started > 300:
            wait = 5
        time.sleep(wait)
        wait = min(wait * 2, 60)


if __name__ == "__main__":
    main()
