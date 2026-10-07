#!/usr/bin/env python3
"""Helpers for the demo Mole launcher (scripts/demo/mo). Standard library only.

Subcommands:
  status REAL_MO ARGS...   run the real `mo status ARGS...` and anonymise every JSON line (streams)
  replay FILE [SECTION_DELAY] [LINE_DELAY]
                           print a recorded output with realistic pacing (@PLACEHOLDERS@ filled in)
  history ARGS...          `mo history` from generated, time-relative demo data
  analyze ARGS...          `mo analyze --json [PATH]` from fixtures
  installer                emulates `mo installer --dry-run`'s key-driven selector over stdin

Nothing here deletes, moves or writes anything except a preview file under $TMPDIR.
"""
import datetime as dt
import hashlib
import json
import os
import random
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(os.path.dirname(HERE), "fixtures")
DEMO_HOME = "/Users/demo"


def out(text=""):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------- status

PROCESS_NAMES = ["WindowServer", "Safari", "Xcode", "Music", "Finder", "kernel_task", "Mail", "Photos"]
BLUETOOTH = [
    {"name": "AirPods Pro", "connected": True, "battery": "85%"},
    {"name": "Magic Keyboard", "connected": True, "battery": "72%"},
    {"name": "Magic Mouse", "connected": False, "battery": ""},
]


def sanitize_status(snap):
    snap["host"] = "My Mac"
    names = {}

    def generic(pid, rank):
        if pid not in names:
            names[pid] = PROCESS_NAMES[rank % len(PROCESS_NAMES)]
        return names[pid]

    for i, proc in enumerate(snap.get("top_processes") or []):
        name = generic(proc.get("pid"), i)
        proc["name"] = name
        proc["command"] = name
    for i, alert in enumerate(snap.get("process_alerts") or []):
        name = names.get(alert.get("pid")) or PROCESS_NAMES[(i + 2) % len(PROCESS_NAMES)]
        alert["name"] = name
        if "command" in alert:
            alert["command"] = name
    if snap.get("bluetooth") is not None:
        snap["bluetooth"] = [dict(b) for b in BLUETOOTH]
    for z in snap.get("zombie_parents") or []:
        z["name"] = "Terminal"
    for i, iface in enumerate(snap.get("network") or []):
        if iface.get("ip"):
            iface["ip"] = "192.168.1.%d" % (20 + i)
    if isinstance(snap.get("proxy"), dict):
        snap["proxy"]["host"] = ""
    for d in snap.get("disks") or []:
        if d.get("external") or str(d.get("mount", "")).startswith("/Volumes/"):
            d["mount"] = "/Volumes/Backup"
    return snap


def cmd_status(real_mo, args):
    proc = subprocess.Popen([real_mo, "status"] + args, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL)

    def stop(signum, _frame):
        try:
            proc.terminate()
        except Exception:
            pass
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        # A pretty-printed `--json` document spans lines: buffer until it parses.
        pending = ""
        for raw in iter(proc.stdout.readline, b""):
            line = raw.decode("utf-8", "replace")
            if not pending and not line.lstrip().startswith("{"):
                sys.stdout.write(line)
                sys.stdout.flush()
                continue
            pending += line
            try:
                snap = json.loads(pending)
            except ValueError:
                continue
            pending = ""
            sys.stdout.write(json.dumps(sanitize_status(snap), ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    except BrokenPipeError:
        proc.terminate()
        return 0
    return proc.wait()


# ---------------------------------------------------------------- replay

def fill(text):
    now = dt.datetime.now()
    return (text.replace("@NOW@", now.strftime("%Y-%m-%d %H:%M:%S"))
                .replace("@CLEAN_LIST@", clean_list_path()))


def clean_list_path():
    base = os.path.join(os.environ.get("TMPDIR", "/tmp"), "burrow-demo")
    return os.path.join(base, "clean-list.txt")


def cmd_replay(path, section_delay=1.2, line_delay=0.08):
    if os.path.basename(path).startswith("clean"):
        # The app reads the preview file named in the summary ("Detailed file list:").
        target = clean_list_path()
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # "clean-dry-run-system.txt" pairs with "clean-list-system.txt".
        variant = os.path.basename(path)[len("clean-dry-run"):]
        with open(os.path.join(FIXTURES, "clean-list" + variant)) as f:
            content = fill(f.read())
        with open(target, "w") as f:
            f.write(content)
    with open(path) as f:
        lines = fill(f.read()).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("➤ ") or stripped == "Performance diagnosis" or stripped.startswith("=" * 20):
            time.sleep(section_delay)
        elif stripped:
            time.sleep(line_delay)
        out(line)
    return 0


# ---------------------------------------------------------------- history

SESSION_PLAN = [
    # command, items, size, actions(removed, trashed, skipped, failed, rebuilt), failed tasks, preview
    ("clean", 182, "6.84GB"), ("optimize", 0, "0B"), ("uninstall", 41, "1.12GB"), ("clean", 97, "2.31GB"),
    ("purge", 6, "2.08GB"), ("installer", 3, "1.46GB"), ("clean", 211, "4.97GB"), ("optimize", 0, "0B"),
    ("uninstall", 18, "486.2MB"), ("clean", 64, "912.5MB"), ("purge", 4, "1.31GB"), ("clean", 143, "3.64GB"),
    ("optimize", 0, "0B"), ("clean", 58, "742.0MB"), ("uninstall", 27, "2.94GB"), ("installer", 2, "684.1MB"),
    ("clean", 176, "5.21GB"), ("purge", 9, "3.87GB"), ("optimize", 0, "0B"), ("clean", 88, "1.43GB"),
    ("uninstall", 12, "318.7MB"), ("clean", 121, "2.76GB"), ("optimize", 0, "0B"), ("clean", 49, "604.3MB"),
    ("purge", 3, "742.9MB"), ("uninstall", 33, "1.67GB"), ("clean", 205, "7.12GB"), ("installer", 4, "2.21GB"),
    ("optimize", 0, "0B"), ("clean", 72, "1.08GB"), ("uninstall", 21, "905.6MB"), ("clean", 134, "3.02GB"),
    ("purge", 5, "1.94GB"), ("optimize", 0, "0B"), ("clean", 66, "887.2MB"), ("uninstall", 9, "212.4MB"),
    ("clean", 158, "4.15GB"), ("optimize", 0, "0B"), ("clean", 91, "1.62GB"), ("installer", 1, "412.8MB"),
]
PREVIEWS = {1, 9, 21, 35}  # indexes of dry-run sessions (logged like real runs)
FAILED_OPTIMIZE = {12}

DELETION_PATHS = {
    "clean": [
        "~/Library/Caches/com.spotify.client", "~/Library/Caches/Google/Chrome/Default/Cache",
        "~/Library/Caches/com.tinyspeck.slackmacgap", "~/Library/Developer/Xcode/DerivedData/WeatherApp-bdwqoxrkme",
        "~/Library/Caches/Homebrew/downloads", "~/.npm/_cacache", "~/Library/Logs/DiagnosticReports",
        "~/Library/Caches/com.apple.Safari/WebKitCache", "~/Library/Application Support/discord/Cache",
        "~/Library/Caches/CocoaPods", "~/Library/Caches/pip", "~/Library/Application Support/Code/Cache",
        "~/Library/Caches/com.figma.Desktop", "~/Library/Caches/Arc",
    ],
    "uninstall": [
        "/Applications/Zoom Rooms.app", "~/Library/Application Support/Zoom Rooms",
        "~/Library/Preferences/com.example.oldeditor.plist", "/Applications/OldEditor.app",
        "~/Library/Caches/com.example.oldeditor", "/Applications/Kindle.app",
        "~/Library/Containers/com.amazon.Kindle", "/Applications/Skype.app",
        "~/Library/Application Support/Skype",
    ],
    "purge": [
        "~/Projects/website/node_modules", "~/Projects/rust-cli/target", "~/Projects/ml-notebook/.venv",
        "~/Projects/design-system/node_modules", "~/Projects/weather-app/build", "~/Code/ios-notes/Pods",
    ],
    "installer": [
        "~/Downloads/Figma-125.4.dmg", "~/Downloads/Docker.dmg", "~/Downloads/Xcode_26.xip",
        "~/Downloads/Zoom.pkg", "~/Desktop/macOS-Tahoe.iso", "~/Downloads/VSCode-darwin-universal.zip",
    ],
}


def build_history(limit):
    rng = random.Random(7)
    now = dt.datetime.now().replace(microsecond=0)
    offset = time.strftime("%z")
    sessions, deletions = [], []
    # Spread sessions over ~3 weeks, newest first, at plausible times of day.
    t = now - dt.timedelta(minutes=23)
    for i, (command, items, size) in enumerate(SESSION_PLAN):
        if i:
            t -= dt.timedelta(hours=rng.uniform(5, 14))
            if t.hour < 8:
                t = t.replace(hour=rng.randint(17, 22), minute=rng.randint(0, 59)) - dt.timedelta(days=1)
        duration = {"clean": rng.randint(70, 160), "optimize": rng.randint(10, 25), "uninstall": rng.randint(15, 45),
                    "purge": rng.randint(20, 60), "installer": rng.randint(5, 15)}[command]
        start, end = t, t + dt.timedelta(seconds=duration)
        preview = i in PREVIEWS
        failed_tasks = 1 if i in FAILED_OPTIMIZE else 0
        if command == "optimize":
            actions = {"removed": 0, "trashed": 0, "skipped": rng.randint(1, 3), "failed": failed_tasks,
                       "rebuilt": rng.randint(2, 5), "other": 0}
            op_count = actions["skipped"] + actions["rebuilt"] + failed_tasks
        elif preview:
            actions = {"removed": 0, "trashed": 0, "skipped": rng.randint(0, 6), "failed": 0, "rebuilt": 0, "other": 0}
            op_count = actions["skipped"]
        else:
            trashed = items if command in ("uninstall", "installer") else rng.randint(0, items // 5)
            skipped = rng.randint(0, 9) if command == "clean" else 0
            actions = {"removed": items - trashed, "trashed": trashed, "skipped": skipped, "failed": 0,
                       "rebuilt": 0, "other": 0}
            op_count = items + skipped
        sessions.append({
            "command": command,
            "started_at": start.strftime("%Y-%m-%d %H:%M:%S"),
            "ended_at": end.strftime("%Y-%m-%d %H:%M:%S"),
            "items": items, "size": size, "operation_count": op_count,
            "failed_tasks": failed_tasks, "actions": actions,
        })
        paths = DELETION_PATHS.get(command)
        if paths:
            count = min(len(paths), 3 if command != "clean" else 4)
            for j, p in enumerate(rng.sample(paths, count)):
                when = start + dt.timedelta(seconds=int(duration * (j + 1) / (count + 1)))
                deletions.append({
                    "timestamp": when.strftime("%Y-%m-%dT%H:%M:%S") + offset,
                    "mode": "trash" if command in ("uninstall", "installer") else "permanent",
                    "status": "dry-run" if preview else "ok",
                    "size_kb": rng.randint(2_000, 1_800_000),
                    "path": p.replace("~", DEMO_HOME, 1),
                })
    deletions.sort(key=lambda d: d["timestamp"], reverse=True)
    return {
        "logs": {"operations": DEMO_HOME + "/Library/Logs/mole/operations.log",
                 "deletions": DEMO_HOME + "/Library/Logs/mole/deletions.log"},
        "limit": limit,
        "sessions": sessions[:limit],
        "deletions": deletions[:limit],
    }


def cmd_history(args):
    limit, as_json = 20, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--json":
            as_json = True
        elif a == "--limit":
            if i + 1 >= len(args):
                sys.stderr.write("Missing value for --limit\n")
                return 1
            i += 1
            if not args[i].isdigit() or not 1 <= int(args[i]) <= 200:
                sys.stderr.write("Invalid value for --limit: %s\n" % args[i])
                return 1
            limit = int(args[i])
        elif a in ("-h", "--help"):
            out("Usage: mo history [--json] [--limit N]")
            return 0
        else:
            sys.stderr.write("Unknown option for mo history: %s\n" % a)
            return 1
        i += 1
    report = build_history(limit)
    if as_json:
        out(json.dumps(report, indent=2))
        return 0
    out()
    out("Mole History")
    out()
    out("Recent sessions")
    for s in report["sessions"]:
        out("  %-10s %s, %s items, %s" % (s["command"], s["started_at"], s["items"], s["size"]))
    out()
    return 0


# ---------------------------------------------------------------- analyze

def overview():
    h = DEMO_HOME
    rows = [
        ("Home", h, 118_472_364_032, False),
        ("User Library", h + "/Library", 46_913_884_160, False),
        ("Applications", "/Applications", 31_854_215_168, False),
        ("System Library", "/Library", 12_408_975_360, False),
        ("Xcode DerivedData", h + "/Library/Developer/Xcode/DerivedData", 9_126_805_504, True),
        ("Xcode Simulators", h + "/Library/Developer/CoreSimulator/Devices", 5_498_748_928, True),
        ("Docker Data", h + "/Library/Containers/com.docker.docker/Data", 3_918_528_512, True),
        ("iOS Backups", h + "/Library/Application Support/MobileSync/Backup", 3_221_225_472, True),
        ("Old Downloads (90d+)", h + "/Downloads", 2_684_354_560, True),
        ("Spotify Cache", h + "/Library/Application Support/Spotify/PersistentCache", 1_207_959_552, True),
        ("Homebrew Cache", h + "/Library/Caches/Homebrew", 865_402_880, True),
        ("System Logs", h + "/Library/Logs", 412_614_656, True),
        ("pip Cache", h + "/Library/Caches/pip", 210_305_024, True),
    ]
    entries = []
    for name, path, size, insight in rows:
        e = {"name": name, "path": path, "size": size, "is_dir": True}
        if insight:
            e["insight"] = True
        entries.append(e)
    return {"path": "/", "overview": True, "entries": entries, "total_size": sum(r[2] for r in rows)}


def directory(path):
    path = os.path.normpath(path)
    name = os.path.basename(path)
    if name == "Projects":
        with open(os.path.join(FIXTURES, "analyze-projects.json")) as f:
            fx = json.load(f)
        entries = []
        for e in fx["entries"]:
            e = dict(e)
            e["path"] = path + "/" + e["name"]
            entries.append(e)
        large = [{"name": os.path.basename(l["rel"]), "path": path + "/" + l["rel"], "size": l["size"]}
                 for l in fx["large_files"]]
        return {"path": path, "overview": False, "entries": entries, "large_files": large,
                "total_size": sum(e["size"] for e in entries), "total_files": fx["total_files"]}
    # Any other folder: a small deterministic listing so drilling down still looks plausible.
    rng = random.Random(int(hashlib.sha1(path.encode()).hexdigest()[:8], 16))
    folders = ["src", "assets", "docs", "tests", "config", "public", "lib", "data", "media", "archive", "tools"]
    files = ["README.md", "notes.txt", "export.csv", "preview.png", "video.mp4", "backup.zip", "report.pdf"]
    entries = []
    for n in rng.sample(folders, rng.randint(4, 8)):
        entries.append({"name": n, "path": path + "/" + n, "size": int(rng.lognormvariate(18, 1.6)), "is_dir": True})
    for n in rng.sample(files, rng.randint(2, 5)):
        entries.append({"name": n, "path": path + "/" + n, "size": int(rng.lognormvariate(15, 2)), "is_dir": False,
                        "last_access": (dt.datetime.utcnow() - dt.timedelta(days=rng.randint(1, 200))).strftime("%Y-%m-%dT%H:%M:%SZ")})
    entries.sort(key=lambda e: e["size"], reverse=True)
    return {"path": path, "overview": False, "entries": entries,
            "total_size": sum(e["size"] for e in entries), "total_files": rng.randint(200, 20000)}


def cmd_analyze(args):
    if "-h" in args or "--help" in args:
        out("Usage: mo analyze [--json] [PATH]")
        return 0
    if not args or args[0] != "--json":
        sys.stderr.write("Demo Mole: only `mo analyze --json [PATH]` is available (the TUI can delete files).\n")
        return 1
    rest = args[1:]
    time.sleep(1.5)
    report = overview() if not rest else directory(rest[0])
    out(json.dumps(report))
    return 0


# ---------------------------------------------------------------- installer

INSTALLERS = [  # name, bytes, source (Mole's list order: full paths sorted byte-wise)
    ("Figma-125.4.dmg", 312_475_648, "Downloads"),
    ("Docker.dmg", 598_736_896, "Downloads"),
    ("Xcode_26.xip", 3_221_225_472, "Downloads"),
    ("Zoom.pkg", 94_371_840, "Downloads"),
    ("macOS-Tahoe.iso", 2_147_483_648, "Desktop"),
]


def bytes_to_human(n):
    if n >= 1_000_000_000:
        s = (n * 100 + 500_000_000) // 1_000_000_000
        return "%d.%02dGB" % (s // 100, s % 100)
    if n >= 1_000_000:
        s = (n * 10 + 500_000) // 1_000_000
        return "%d.%01dMB" % (s // 10, s % 10)
    if n >= 1000:
        return "%dKB" % ((n + 500) // 1000)
    return "%dB" % n


def read_key():
    b = os.read(0, 1)
    return b.decode("latin-1") if b else ""


def cmd_installer(args):
    for a in args:
        if a in ("-h", "--help"):
            out("Usage: mo installer [--dry-run]")
            return 0
    clear = "\r\033[2K"
    items = sorted(INSTALLERS, key=lambda x: ("/Users/demo/" + x[2] + "/" + x[0]).encode())
    rows = ["%-40s %8s | %-10s" % (n, bytes_to_human(b), s) for n, b, s in items]
    selected = [False] * len(items)
    cursor = 0
    per_page = 18
    out("→ DRY RUN MODE, No installer files will be removed")
    out()
    time.sleep(1.0)
    out()

    def draw():
        size = sum(items[i][1] for i in range(len(items)) if selected[i])
        sys.stdout.write("\033[HSelect Installers to Remove , %s, %d selected\n" % (bytes_to_human(size), sum(selected)))
        sys.stdout.write(clear + "\n")
        for i, row in enumerate(rows):
            box = "●" if selected[i] else "○"
            sys.stdout.write("%s%s %s %s\n" % (clear, "➤" if i == cursor else " ", box, row))
        for _ in range(len(rows), per_page):
            sys.stdout.write(clear + "\n")
        sys.stdout.write(clear + "\n")
        sys.stdout.write(clear + "↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit\n")
        sys.stdout.flush()

    while True:
        draw()
        k = read_key()
        if k == "\x1b":
            k2 = read_key()
            if k2 == "[":
                k3 = read_key()
                if k3 == "A" and cursor > 0:
                    cursor -= 1
                elif k3 == "B" and cursor < len(items) - 1:
                    cursor += 1
            else:
                out()
                return 0
        elif k == " ":
            selected[cursor] = not selected[cursor]
        elif k in ("a", "A"):
            selected = [True] * len(items)
        elif k in ("i", "I"):
            selected = [not s for s in selected]
        elif k in ("q", "Q", "\x03"):
            out()
            return 0
        elif k in ("", "\n", "\r"):
            break
    chosen = [items[i] for i in range(len(items)) if selected[i]]
    if not chosen:
        out()
        return 0
    out("Files to be removed:")
    for n, b, _ in chosen:
        out("  ✓ %s , %s" % (n, bytes_to_human(b)))
    out()
    sys.stdout.write("➤ Delete %d installers, %s  Enter confirm, ESC cancel: " % (len(chosen), bytes_to_human(sum(c[1] for c in chosen))))
    sys.stdout.flush()
    k = read_key()
    if k not in ("", "\n", "\r"):
        out()
        return 0
    sys.stdout.write("\r\033[K")
    out()
    kb = sum((c[1] + 1023) // 1024 for c in chosen)
    out()
    out("=" * 70)
    out("Dry run complete - no changes made")
    out("Would remove %d installers, free %.2fMB" % (len(chosen), kb / 1024))
    out("=" * 70)
    out()
    return 0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "status":
        return cmd_status(args[0], args[1:])
    if cmd == "replay":
        delays = [float(x) for x in args[1:3]]
        return cmd_replay(args[0], *delays)
    if cmd == "history":
        return cmd_history(args)
    if cmd == "analyze":
        return cmd_analyze(args)
    if cmd == "installer":
        return cmd_installer(args)
    sys.stderr.write("demo.py: unknown helper %s\n" % cmd)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
