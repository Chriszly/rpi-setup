#!/usr/bin/env python3
"""Log who is online on the TeamSpeak server, and when (tasks/teamspeak.sh).

Runs in the teamspeak-usage container next to the server. It logs in to the
server's SSH query as serveradmin (query clients are hidden from users),
reads who is online, registers for join and leave events and writes, in
$USAGE_DATA (default /data):

  sessions.jsonl  one line per finished visit: uid, nick, start, end (epoch)
  online.json     who is online now, and when that was last confirmed
  usage.json      the summary the start page shows (copied there by the web
                  task's rpi-setup-web-links timer)

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
RECENT = 15

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


def read_sessions():
    sessions = []
    try:
        with open(path("sessions.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    s = json.loads(line)
                    sessions.append({"uid": str(s["uid"]), "nick": str(s["nick"]),
                                     "start": int(s["start"]), "end": int(s["end"])})
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
                                          "since": int(c["since"])}
            except (KeyError, TypeError, ValueError):
                continue
        self.connected = False
        self.pruned = 0

    def end_visit(self, c, end):
        line = json.dumps({"uid": c["uid"], "nick": c["nick"], "start": c["since"],
                           "end": max(int(end), c["since"])}, ensure_ascii=False)
        with open(path("sessions.jsonl"), "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def save(self, now):
        if self.connected:
            self.checked = int(now)
        write_json("online.json", {"checked": self.checked, "clients": self.online})
        write_json("usage.json", summary(self.online, read_sessions(), now))

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
            self.online[rec["clid"]] = {"uid": uid, "nick": nick, "since": since}
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
                                            "since": int(now)}
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


def summary(online, sessions, now):
    """The start page's view: who is online, the last visits and, per person,
    the time online over the last 7 days."""
    week = now - WEEK
    people = {}

    def person(uid, nick, last):
        p = people.setdefault(uid or nick, {"nick": nick, "last": 0, "week": 0, "visits": 0,
                                            "online": False})
        if last >= p["last"]:
            p["nick"], p["last"] = nick, last
        return p

    for s in sessions:
        p = person(s["uid"], s["nick"], s["end"])
        if s["end"] >= week:
            p["week"] += s["end"] - max(s["start"], week)
            p["visits"] += 1
    for c in online.values():
        p = person(c["uid"], c["nick"], now)
        p["week"] += now - max(c["since"], week)
        p["visits"] += 1
        p["online"] = True
    users = [{"nick": p["nick"], "online": p["online"], "last_seen": iso(p["last"]),
              "week_seconds": int(p["week"]), "week_visits": p["visits"]}
             for p in people.values() if p["visits"] or p["online"]]
    users.sort(key=lambda u: (not u["online"], -u["week_seconds"], u["nick"].lower()))
    recent = sorted(sessions, key=lambda s: s["end"], reverse=True)[:RECENT]
    return {
        "updated": iso(now),
        "days": DAYS,
        "online": sorted(({"nick": c["nick"], "since": iso(c["since"])} for c in online.values()),
                         key=lambda c: c["since"]),
        "recent": [{"nick": s["nick"], "start": iso(s["start"]), "end": iso(s["end"])} for s in recent],
        "users": users,
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
        clients = q.command("clientlist -uid")
        usage.reconcile(clients, time.time())
        log("Connected; %d online" % len(usage.online))
        heard = time.time()
        while True:
            usage.prune(time.time())
            usage.save(time.time())
            q.send("version")
            end = time.time() + TICK
            while time.time() < end:
                try:
                    q.line(end - time.time())
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
        state = read_json("online.json", {})
        json.dump(summary(state.get("clients") or {}, read_sessions(), time.time()), sys.stdout,
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
