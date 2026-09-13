import argparse
import datetime as dt
import json
import os
import pathlib
import re
import selectors
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

VERSION = 1
MAX_OUTPUT = 65536
MAX_HISTORY = 1000
UTC = dt.timezone.utc


def text(value, name, limit=200):
    if not isinstance(value, str) or not value.strip() or len(value.encode()) > limit or "\0" in value:
        raise ValueError("Invalid " + name)
    return value


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", value):
        raise ValueError("Invalid identifier")
    return value


def next_due(job, now):
    zone = ZoneInfo(job["timezone"])
    local = dt.datetime.fromtimestamp(now, zone)
    hour, minute = map(int, job["time"].split(":"))
    day = dt.date.fromisoformat(job["date"]) if job["repeat"] == "once" else local.date()
    for offset in range(370 if job["repeat"] == "daily" else 1):
        candidate = dt.datetime.combine(day + dt.timedelta(days=offset), dt.time(hour, minute), zone)
        stamp = candidate.timestamp()
        if dt.datetime.fromtimestamp(stamp, zone).replace(tzinfo=None) != candidate.replace(tzinfo=None):
            continue
        if stamp > now:
            return stamp
    return None


def validate_job(value, now):
    if not isinstance(value, dict):
        raise ValueError("Invalid schedule")
    allowed = {"id", "revision", "title", "directory", "agent", "model", "prompt", "repeat", "date", "time", "timezone", "timeout"}
    if set(value) - allowed:
        raise ValueError("Unknown schedule field")
    job = {key: value.get(key, "") for key in allowed}
    job["id"] = identifier(job["id"])
    for key, limit in [("title", 120), ("directory", 2048), ("prompt", 16000), ("timezone", 100)]:
        job[key] = text(job[key], key, limit)
    if not pathlib.Path(job["directory"]).is_absolute() or not pathlib.Path(job["directory"]).is_dir():
        raise ValueError("Choose an existing absolute repository directory")
    if job["agent"] not in ("codex", "claude"):
        raise ValueError("Unsupported agent")
    if job["model"] and not re.fullmatch(r"[a-zA-Z0-9_.:/-]{1,100}", job["model"]):
        raise ValueError("Invalid model")
    if job["repeat"] not in ("daily", "once") or not re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", job["time"]):
        raise ValueError("Choose a daily or one-shot time")
    try:
        ZoneInfo(job["timezone"])
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError("Unknown IANA timezone") from None
    if job["repeat"] == "once":
        dt.date.fromisoformat(job["date"])
    for key, minimum, maximum in [("timeout", 60, 14400), ("revision", 0, 9007199254740991)]:
        value = job[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value != int(value) or not minimum <= value <= maximum:
            raise ValueError("Invalid " + key)
        job[key] = int(value)
    if next_due(job, now) is None:
        raise ValueError("Scheduled time is past or does not exist in that timezone")
    return job


def storage_root(owner):
    if not re.fullmatch(r"[a-f0-9]{64}", owner):
        raise ValueError("Invalid plugin owner")
    base = pathlib.Path(os.environ.get("XDG_STATE_HOME", str(pathlib.Path.home() / ".local/state")))
    return base / "dazzle/scheduler" / owner


class Store:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        if self.root.is_symlink():
            raise ValueError("Scheduler directory must not be a link")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        file = self.root / "schedules.sqlite"
        if file.is_symlink():
            raise ValueError("Scheduler database must not be a link")
        self.db = sqlite3.connect(file, timeout=10, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, VERSION):
            self.db.close()
            raise ValueError("Unsupported scheduler data version")
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT OR IGNORE INTO settings VALUES ('paused', 'false');
            CREATE TABLE IF NOT EXISTS schedules (
                id TEXT PRIMARY KEY, revision INTEGER NOT NULL, document TEXT NOT NULL,
                enabled INTEGER NOT NULL, next_due REAL);
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, slot TEXT NOT NULL,
                document TEXT NOT NULL, status TEXT NOT NULL, started REAL NOT NULL,
                finished REAL, exit_code INTEGER, pid INTEGER,
                UNIQUE(schedule_id, slot));
            CREATE INDEX IF NOT EXISTS run_time ON runs(started DESC);
            PRAGMA user_version=1;
        """)

    def close(self):
        self.db.close()

    def setting(self, key, fallback=""):
        row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row[0] if row else fallback

    def set_setting(self, key, value):
        self.db.execute("INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    def summary(self, row, full=False):
        job = json.loads(row["document"])
        result = {key: job[key] for key in ("id", "title", "agent", "repeat", "time", "timezone")}
        if full:
            result = job
        result.update(revision=row["revision"], enabled=bool(row["enabled"]), next_due=row["next_due"])
        due = row["next_due"]
        result["next_label"] = dt.datetime.fromtimestamp(due, ZoneInfo(job["timezone"])).isoformat(timespec="minutes") if due else "Finished"
        return result

    def save(self, value, now):
        job = validate_job(value, now)
        if not shutil.which(job["agent"]):
            raise ValueError("Agent executable is not installed: " + job["agent"])
        self.db.execute("BEGIN IMMEDIATE")
        try:
            previous = self.db.execute("SELECT * FROM schedules WHERE id=?", (job["id"],)).fetchone()
            if (previous["revision"] if previous else 0) != job["revision"]:
                raise ValueError("Schedule changed; refresh before saving")
            if not previous and self.db.execute("SELECT count(*) FROM schedules").fetchone()[0] >= 200:
                raise ValueError("Schedule quota reached")
            job["revision"] += 1
            self.db.execute("INSERT INTO schedules VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, document=excluded.document, next_due=excluded.next_due",
                            (job["id"], job["revision"], json.dumps(job), 1, next_due(job, now)))
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        return {"id": job["id"], "revision": job["revision"]}

    def claim(self, job_id, slot, now, automatic=False):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute("SELECT * FROM schedules WHERE id=?", (identifier(job_id),)).fetchone()
            if not row:
                raise ValueError("Schedule is unavailable")
            if self.setting("paused") == "true" or automatic and not row["enabled"]:
                raise ValueError("Host schedules are paused")
            previous = self.db.execute("SELECT id FROM runs WHERE schedule_id=? AND slot=?", (job_id, slot)).fetchone()
            if previous:
                self.db.execute("COMMIT")
                return previous[0], False
            if self.db.execute("SELECT count(*) FROM runs").fetchone()[0] >= MAX_HISTORY:
                raise ValueError("Run history quota reached; existing history is retained")
            if self.db.execute("SELECT count(*) FROM runs WHERE status IN ('queued', 'running')").fetchone()[0] >= 2:
                raise ValueError("Two runs are already active")
            run_id = uuid.uuid4().hex
            missed = automatic and now - row["next_due"] > 300
            status = "missed" if missed else "queued"
            self.db.execute("INSERT INTO runs(id, schedule_id, slot, document, status, started, finished) VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (run_id, job_id, slot, row["document"], status, now, now if missed else None))
            if automatic:
                job = json.loads(row["document"])
                following = next_due(job, now)
                self.db.execute("UPDATE schedules SET next_due=?, enabled=? WHERE id=?", (following, int(following is not None), job_id))
            self.db.execute("COMMIT")
            return run_id, not missed
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def dispatch(self, operation, args, now=None):
        now = time.time() if now is None else now
        if operation == "list":
            offset = int(args.get("offset", 0))
            if not 0 <= offset <= 200:
                raise ValueError("Invalid page")
            rows = self.db.execute("SELECT * FROM schedules ORDER BY next_due, id LIMIT 32 OFFSET ?", (offset,)).fetchall()
            return {"items": [self.summary(row) for row in rows], "offset": offset, "more": len(rows) == 32,
                    "paused": self.setting("paused") == "true", "error": self.setting("error")}
        if operation == "get":
            row = self.db.execute("SELECT * FROM schedules WHERE id=?", (identifier(args.get("id")),)).fetchone()
            if not row:
                raise ValueError("Schedule is unavailable")
            return self.summary(row, True)
        if operation == "save":
            return self.save(args.get("schedule"), now)
        if operation in ("pause", "resume"):
            job_id = identifier(args.get("id"))
            row = self.db.execute("SELECT * FROM schedules WHERE id=?", (job_id,)).fetchone()
            if not row:
                raise ValueError("Schedule is unavailable")
            due = next_due(json.loads(row["document"]), now) if operation == "resume" else row["next_due"]
            if operation == "resume" and due is None:
                raise ValueError("Edit the expired schedule before resuming")
            self.db.execute("UPDATE schedules SET enabled=?, next_due=?, revision=revision+1 WHERE id=?", (int(operation == "resume"), due, job_id))
            return {"paused": operation == "pause"}
        if operation in ("pause_scope", "resume_scope"):
            self.set_setting("paused", "true" if operation == "pause_scope" else "false")
            return {"paused": operation == "pause_scope"}
        if operation == "history":
            offset = int(args.get("offset", 0))
            if not 0 <= offset <= MAX_HISTORY:
                raise ValueError("Invalid history page")
            rows = self.db.execute("SELECT * FROM runs ORDER BY started DESC LIMIT 32 OFFSET ?", (offset,)).fetchall()
            return {"items": [{"id": row["id"], "title": json.loads(row["document"])["title"],
                                "status": row["status"], "started": row["started"], "finished": row["finished"],
                                "started_label": dt.datetime.fromtimestamp(row["started"], UTC).isoformat(timespec="seconds"),
                                "exit_code": row["exit_code"]} for row in rows], "more": len(rows) == 32, "offset": offset}
        if operation == "output":
            run_id = identifier(args.get("id"))
            row = self.db.execute("SELECT status FROM runs WHERE id=?", (run_id,)).fetchone()
            if not row:
                raise ValueError("Run is unavailable")
            file = self.root / (run_id + ".log")
            if file.is_symlink():
                raise ValueError("Invalid run output path")
            output = b""
            if file.exists():
                with file.open("rb") as stream:
                    stream.seek(max(0, file.stat().st_size - MAX_OUTPUT))
                    output = stream.read(MAX_OUTPUT)
            decoded = output.decode("utf-8", errors="replace").encode()[-MAX_OUTPUT:].decode("utf-8", errors="ignore")
            return {"status": row[0], "text": decoded, "bytes": len(output)}
        if operation == "usage":
            return {"schema_version": VERSION, "schedules": self.db.execute("SELECT count(*) FROM schedules").fetchone()[0],
                    "runs": self.db.execute("SELECT count(*) FROM runs").fetchone()[0],
                    "bytes": sum(file.stat().st_size for file in self.root.iterdir() if file.is_file() and not file.is_symlink()),
                    "history_limit": MAX_HISTORY}
        raise ValueError("Unsupported scheduler operation")


def launch(store, run_id):
    root = store.root
    try:
        subprocess.run(["systemd-run", "--user", "--quiet", "--collect",
                    "--unit=dazzle-run-" + root.name[:12] + "-" + identifier(run_id),
                    "--setenv=PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
                    "--setenv=XDG_STATE_HOME=" + str(root.parents[2]),
                    "--property=RuntimeMaxSec=14460", "--property=TimeoutStopSec=5",
                    sys.executable, str(root / "runner.py"), "worker", root.name, run_id],
                       check=True, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        store.db.execute("UPDATE runs SET status='failed', finished=? WHERE id=? AND status='queued'", (time.time(), run_id))
        atomic_write(root / (run_id + ".log"), str(error).encode()[-MAX_OUTPUT:])
        raise


def worker(root, run_id):
    store = Store(root)
    store.db.execute("BEGIN IMMEDIATE")
    row = store.db.execute("SELECT * FROM runs WHERE id=?", (identifier(run_id),)).fetchone()
    if not row or row["status"] != "queued":
        store.db.execute("COMMIT")
        store.close()
        return
    if store.setting("paused") == "true":
        store.db.execute("UPDATE runs SET status='canceled', finished=? WHERE id=? AND status='queued'", (time.time(), run_id))
        store.db.execute("COMMIT")
        store.close()
        return
    claimed = store.db.execute("UPDATE runs SET status='running', pid=? WHERE id=? AND status='queued'", (os.getpid(), run_id))
    store.db.execute("COMMIT")
    if claimed.rowcount != 1:
        store.close()
        return
    job = json.loads(row["document"])
    log = bytearray()
    status, exit_code = "failed", None
    process = None
    try:
        command = [job["agent"], "exec", "--json", "-"] if job["agent"] == "codex" else [job["agent"], "--print", "--output-format", "json"]
        if job["model"]:
            command.extend(["--model", job["model"]])
        with tempfile.TemporaryFile() as prompt:
            prompt.write(job["prompt"].encode())
            prompt.seek(0)
            process = subprocess.Popen(command, cwd=job["directory"], stdin=prompt, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + job["timeout"]
        last_flush, dirty = 0.0, False
        while selector.get_map():
            if time.monotonic() >= deadline:
                os.killpg(process.pid, signal.SIGKILL)
                status = "timeout"
                break
            for key, _ in selector.select(timeout=1):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                log.extend(chunk)
                if len(log) > MAX_OUTPUT:
                    del log[:-MAX_OUTPUT]
                dirty = True
            if dirty and time.monotonic() - last_flush >= 0.25:
                atomic_write(root / (run_id + ".log"), bytes(log))
                last_flush, dirty = time.monotonic(), False
        selector.close()
        exit_code = process.wait(timeout=max(1, deadline - time.monotonic()))
        if status != "timeout":
            status = "completed" if exit_code == 0 else "failed"
    except BaseException as error:
        if isinstance(error, subprocess.TimeoutExpired):
            status = "timeout"
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        log.extend(str(error).encode())
        log = log[-MAX_OUTPUT:]
    finally:
        if process is not None and process.stdout is not None:
            process.stdout.close()
        atomic_write(root / (run_id + ".log"), bytes(log))
        store.db.execute("UPDATE runs SET status=?, finished=?, exit_code=? WHERE id=?", (status, time.time(), exit_code, run_id))
        store.close()


def atomic_write(file, value):
    if file.is_symlink():
        raise ValueError("Refusing linked scheduler file")
    temporary = file.with_name(file.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(value)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, file)


def probe():
    user_service = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, timeout=10).returncode == 0 if shutil.which("systemctl") else False
    linger = False
    if shutil.which("loginctl"):
        result = subprocess.run(["loginctl", "show-user", str(os.getuid()), "--property=Linger", "--value"], capture_output=True, text=True, timeout=10)
        linger = result.returncode == 0 and result.stdout.strip() == "yes"
    timezone = "UTC"
    if shutil.which("timedatectl"):
        result = subprocess.run(["timedatectl", "show", "--property=Timezone", "--value"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            timezone = result.stdout.strip()
    return {"api_version": VERSION, "supported": sys.platform == "linux" and user_service and linger,
            "reason": "" if user_service and linger else "Linux systemd user service and login linger are required for unattended runs",
            "agents": [agent for agent in ("codex", "claude") if shutil.which(agent)], "timezone": timezone}


def inspect(root):
    result = probe()
    installed = (root / "runner.py").is_file() and (root / "schedules.sqlite").is_file()
    active = False
    if installed and shutil.which("systemctl"):
        active = subprocess.run(["systemctl", "--user", "is-active", "--quiet", "dazzle-schedule-" + root.name + ".timer"], capture_output=True, timeout=10).returncode == 0
    return {**result, "installed": installed, "timer_active": active}


def setup(root, source):
    capability = probe()
    if not capability["supported"]:
        raise ValueError(capability["reason"])
    text(source, "host runner source", 65536)
    store = Store(root)
    store.close()
    runner = root / "runner.py"
    atomic_write(runner, source.encode())
    unit_directory = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", str(pathlib.Path.home() / ".config"))) / "systemd/user"
    unit_directory.mkdir(parents=True, exist_ok=True)
    name = "dazzle-schedule-" + root.name
    def unit_quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
    service = "[Unit]\nDescription=Dazzle agent schedule dispatch\n[Service]\nType=oneshot\nExecStart=" + " ".join(map(unit_quote, [sys.executable, str(runner), "tick", root.name])) + "\nEnvironment=" + unit_quote("PATH=" + os.environ.get("PATH", "/usr/bin:/bin")) + "\nEnvironment=" + unit_quote("XDG_STATE_HOME=" + str(root.parents[2])) + "\nTimeoutStartSec=30\n"
    timer = "[Unit]\nDescription=Dazzle agent schedules\n[Timer]\nOnCalendar=*-*-* *:*:00\nAccuracySec=1s\nPersistent=true\n[Install]\nWantedBy=timers.target\n"
    atomic_write(unit_directory / (name + ".service"), service.encode())
    atomic_write(unit_directory / (name + ".timer"), timer.encode())
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, capture_output=True, timeout=10)
    subprocess.run(["systemctl", "--user", "enable", "--now", name + ".timer"], check=True, capture_output=True, timeout=10)
    return {"installed": True, "timer_active": True, **capability}


def tick(root):
    store = Store(root)
    now = time.time()
    for row in store.db.execute("SELECT id, status, pid, started FROM runs WHERE status IN ('queued','running')").fetchall():
        alive = False
        if row["pid"]:
            try:
                command = pathlib.Path("/proc") / str(row["pid"]) / "cmdline"
                alive = row["id"].encode() in command.read_bytes()
            except OSError:
                pass
        if not alive and now - row["started"] > 120:
            store.db.execute("UPDATE runs SET status='interrupted', finished=? WHERE id=?", (now, row["id"]))
    if store.setting("paused") != "true":
        for row in store.db.execute("SELECT id, next_due FROM schedules WHERE enabled=1 AND next_due <= ? ORDER BY next_due LIMIT 32", (now,)).fetchall():
            try:
                run_id, fresh = store.claim(row["id"], str(int(row["next_due"])), now, automatic=True)
                if fresh:
                    launch(store, run_id)
                store.set_setting("error", "")
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                store.set_setting("error", str(error))
    store.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation")
    parser.add_argument("owner")
    parser.add_argument("run_id", nargs="?")
    args = parser.parse_args()
    os.umask(0o077)
    root = storage_root(args.owner)
    if args.operation == "worker":
        worker(root, args.run_id)
        return
    if args.operation == "tick":
        tick(root)
        return
    request = sys.stdin.buffer.read(98305)
    if len(request) > 98304:
        raise ValueError("Host request exceeds its limit")
    value = json.loads(request or b"{}")
    if not isinstance(value, dict):
        raise ValueError("Invalid host request")
    if args.operation == "inspect":
        result = inspect(root)
    elif args.operation == "setup":
        result = setup(root, value.get("source"))
    else:
        if not (root / "runner.py").is_file():
            raise ValueError("Enable scheduling on this host first")
        store = Store(root)
        try:
            if args.operation == "run":
                run_id, fresh = store.claim(value.get("id"), "manual:" + identifier(value.get("request_id")), time.time())
                if fresh:
                    launch(store, run_id)
                result = {"id": run_id}
            else:
                result = store.dispatch(args.operation, value)
        finally:
            store.close()
    print(json.dumps({"ok": True, "value": result}, ensure_ascii=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        sys.exit(1)
