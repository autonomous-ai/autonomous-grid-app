import 'dart:io';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';

/// The skill that lets either agent start a service the user can actually open.
///
/// Every command an agent runs lives in a session the runner tears down when the
/// tool call returns: Codex's `exec_command` reaps the whole group, so a server
/// started with `nohup … &` is gone *between two tool calls* — the agent's own
/// health check passes, it reports success, and the user gets "connection
/// refused". Watching one turn burn five calls rediscovering that (nohup →
/// setsid → disown → screen) is what this skill is for: hand the process to a
/// supervisor that has nothing to do with the agent's session, first try.
const String kGridServeSkillName = 'grid-serve';

/// Where a started service's log and its record live — one folder the agent can
/// point the user at, and the app can list later if it ever grows a UI for this.
Directory gridServeStateDir() => GridPaths.servicesDir;

/// The `grid-serve` skill as it lands in [skillDir]: the card, plus the one script
/// that starts, checks, tails and stops a service.
///
/// The card names the script by absolute path, so it's a function of where the
/// skill lands — hence built from [skillDir] rather than a constant.
GridSkillFiles gridServeSkillFiles(
  Directory skillDir, {
  String? uvPath,
  String? stateDir,
}) => GridSkillFiles(
  card: gridServeSkillMd(
    uvPath: uvPath ?? gridSkillUvPath(),
    serveScriptPath: '${skillDir.path}/scripts/serve.py',
    stateDir: stateDir ?? gridServeStateDir().path,
  ),
  files: const {'scripts/serve.py': kGridServeScript},
);

/// Write (or refresh) the `grid-serve` skill into [skillDir]. Idempotent.
Future<void> writeGridServeSkill(
  Directory skillDir, {
  String? uvPath,
  String? stateDir,
}) => writeSkillFolder(
  skillDir,
  gridServeSkillFiles(skillDir, uvPath: uvPath, stateDir: stateDir),
);

/// The skill card both agents read.
///
/// The frontmatter is the only part read before it fires, so the description
/// carries every phrasing that should trigger it — including "why doesn't
/// localhost answer", which is how the user meets this bug. The body then leads
/// with the trap (`nohup` looks like it worked) because an agent that skips that
/// line will cheerfully report a dead server as running.
String gridServeSkillMd({
  required String uvPath,
  required String serveScriptPath,
  required String stateDir,
}) =>
    '''
---
name: $kGridServeSkillName
description: Start, check, tail or stop a long-running local service — a dev server, API, watcher, queue worker — so it keeps running after your turn ends and the user can actually open it. Use whenever the user asks you to run or start a server, restart one, find out whether it is up, open localhost, read a server's log, or stop it.
tags: [server, dev-server, background, localhost, service, grid]
triggers:
  - user asks to run / start / restart / stop a server, api, app, worker or watcher
  - user asks whether the server is up, or why localhost / a port doesn't answer
  - user asks to see a running service's log
  - "chạy server", "start server", "khởi động lại server", "mở localhost", "server chết rồi", "xem log server"
---

# Run a service that outlives your turn

**Never start a service with `nohup … &`, `setsid …`, `… & disown`, or a bare
`&`.** Every command you run sits in a session the runner kills the moment your
tool call returns. A server started that way is alive for your health check and
**dead before the user can open it** — so you report success and the user gets
"connection refused". This skill hands the process to a real supervisor
(launchd on macOS, `screen` elsewhere) that outlives your session.

## Start (or restart) a service
```
"$uvPath" run --no-project python3 "$serveScriptPath" start <name> \\
  --dir <absolute project dir> --cmd "<the command>" [--port <port>]
```
- `<name>` is a short slug the user would recognise (`fastify-api`, `web`). Same
  name twice = restart, never a second copy.
- `--cmd` is one shell string: `"node server.js"`, `"npm run dev"`, `"pnpm dev"`.
- `--port` makes it wait until the port actually answers, so what it prints is
  the truth rather than a hope.

It prints the supervisor it used, the pid, whether the port answered, and the
first lines of the log. **Read that output before you reply.**

## Check what's running
```
"$uvPath" run --no-project python3 "$serveScriptPath" status [<name>]
```

## Read the log
```
"$uvPath" run --no-project python3 "$serveScriptPath" logs <name> [-n 80]
```

## Stop it
```
"$uvPath" run --no-project python3 "$serveScriptPath" stop <name>
```

## "Port already in use" — find out who, don't guess
```
"$uvPath" run --no-project python3 "$serveScriptPath" port <port> [--release]
```
Names the process holding the port and whether it is one of yours. `--release`
stops it **only** if this skill started it; anything else is the user's program,
so it says whose it is and leaves it alone. Reach for this the moment you see
`EADDRINUSE` — it is a question with an answer, not a mystery about IPv6 or
TIME_WAIT.

## A long one-shot command (install, build, test suite)
```
"$uvPath" run --no-project python3 "$serveScriptPath" run <name> \\
  --cmd "<command>" [--dir <dir>] [--timeout <seconds>]
```
Runs it to completion under a time limit and prints the exit code, how long it
took, and the tail of its output. This is the substitute for `timeout` (which
macOS does not have): use it for `npm install`, a build, a test run — anything
that might outlast a normal call. On the limit it kills the whole process group
and says so, rather than leaving something half-running behind.

Logs and records live in `$stateDir` (`<name>.log`, `<name>.json`).

## Rules
- After `start`, tell the user the URL **only if the port answered**. If it
  didn't, say so and quote the log — a service that died on boot is a bug to fix,
  not something to announce as running.
- Crashed or exited on its own? `logs` first, fix the cause, then `start` again.
- The user asked to "stop the server": use `stop <name>`, not `kill` on a pid you
  found in `ps` — the supervisor would restart it or leave a stale record behind.
- A short command that finishes on its own is a normal command — don't wrap it.
  `run` is for the long ones; `start` is only for something meant to keep running.

## If it fails
- Exit 2 = no supervisor available (no `launchctl`, no `screen`, no `tmux`); it
  falls back to a detached process, which may not survive. Say that plainly.
- Exit 1 = the service started and then exited, or the port never answered; the
  log tail it prints is the reason.
''';

/// The one script behind the card: start / status / logs / stop.
///
/// Stdlib only, and run through the pinned `uv` so it never depends on a system
/// `python3`. The mechanism is chosen at start time and written into the service's
/// record, so `status`/`stop` don't have to guess how it was launched.
///
/// The started command carries the agent's own `PATH`: a launchd job gets a
/// minimal environment, and the node/pnpm the user actually runs usually comes
/// from a version manager on the shell's PATH (`~/.nvm/...`), which launchd would
/// otherwise not find.
const String kGridServeScript = r'''#!/usr/bin/env python3
"""Start a long-running local service so it survives the agent's tool call.

Every command an agent runs lives in a session that is torn down when the call
returns, which kills a `nohup ... &` server with it. So the service is handed to
a supervisor outside that session:

    launchd   (macOS)  - launchctl submit, the job is launchd's child
    screen    (any)    - a detached session, its own process group
    tmux      (any)    - same idea
    detached  (last)   - double-fork + setsid; may still be reaped

Usage:
    serve.py start <name> --dir <dir> --cmd "<command>" [--port N] [--wait S]
    serve.py status [<name>]
    serve.py logs <name> [-n 80]
    serve.py stop <name>
    serve.py port <port> [--release]
    serve.py run <name> --cmd "<command>" [--dir <dir>] [--timeout S]

Exit codes: 0 ok, 1 the service isn't running (or died), 2 no supervisor found.
"""

import argparse
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

STATE_DIR = Path(
    os.environ.get("GRID_SERVICES_DIR")
    or (Path.home() / ".grid" / "app" / "services")
)


def record_path(name):
    return STATE_DIR / f"{name}.json"


def log_path(name):
    return STATE_DIR / f"{name}.log"


def load_record(name):
    try:
        return json.loads(record_path(name).read_text())
    except (OSError, ValueError):
        return None


def save_record(record):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    record_path(record["name"]).write_text(json.dumps(record, indent=1))


def label_for(name):
    return f"grid.serve.{name}"


def session_for(name):
    return f"grid-serve-{name}"


def tail(path, lines):
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return ""
    return "\n".join(text.splitlines()[-lines:])


def port_answers(port, timeout=0.4):
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, int(port)), timeout=timeout):
                return True
        except OSError:
            continue
    return False


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def launchd_pid(label):
    """The pid launchd reports for a submitted job, or None when it has none."""
    out = run_capture(["launchctl", "list", label])
    if out is None:
        return None
    for line in out.splitlines():
        stripped = line.strip()
        if stripped.startswith('"PID"'):
            digits = "".join(ch for ch in stripped.split("=")[-1] if ch.isdigit())
            return int(digits) if digits else None
    return None


def run_capture(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def shell_line(directory, command, log=None):
    """The line a supervisor runs: our PATH, the project dir, then the command.

    Deliberately no `exec`: the command is whatever the agent typed, and
    `exec npm install && npm test` would exec the first segment and silently drop
    the rest. One extra shell in the tree is cheaper than losing half a command —
    and stopping kills the process group, so the wrapper is not in the way.
    """
    path = shlex.quote(os.environ.get("PATH", ""))
    parts = [f"export PATH={path}", f"cd {shlex.quote(str(directory))}"]
    redirect = f" >> {shlex.quote(str(log))} 2>&1" if log else ""
    parts.append(f"{{ {command} ; }}{redirect}")
    return "; ".join(parts)


def start_launchd(name, directory, command, log):
    if not shutil.which("launchctl"):
        return None
    label = label_for(name)
    subprocess.run(["launchctl", "remove", label], capture_output=True)
    argv = [
        "launchctl",
        "submit",
        "-l",
        label,
        "-o",
        str(log),
        "-e",
        str(log),
        "--",
        "/bin/sh",
        "-c",
        shell_line(directory, command),
    ]
    done = subprocess.run(argv, capture_output=True, text=True)
    if done.returncode != 0:
        return None
    return {"mechanism": "launchd", "label": label}


def start_multiplexer(name, directory, command, log):
    session = session_for(name)
    line = shell_line(directory, command, log)
    if shutil.which("screen"):
        subprocess.run(["screen", "-S", session, "-X", "quit"], capture_output=True)
        done = subprocess.run(
            ["screen", "-dmS", session, "/bin/sh", "-c", line],
            capture_output=True,
        )
        if done.returncode == 0:
            return {"mechanism": "screen", "session": session}
    if shutil.which("tmux"):
        subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)
        done = subprocess.run(
            ["tmux", "new-session", "-d", "-s", session, "/bin/sh", "-c", line],
            capture_output=True,
        )
        if done.returncode == 0:
            return {"mechanism": "tmux", "session": session}
    return None


def start_detached(name, directory, command, log):
    """Last resort: a double-forked, own-session child. Better than nothing, but
    a runner that reaps by process tree can still take it."""
    handle = open(log, "ab", buffering=0)
    process = subprocess.Popen(
        ["/bin/sh", "-c", shell_line(directory, command)],
        stdout=handle,
        stderr=handle,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=str(directory),
    )
    return {"mechanism": "detached", "pid": process.pid}


def running_pid(record):
    """The live pid for a recorded service, or None when nothing is running."""
    mechanism = record.get("mechanism")
    if mechanism == "launchd":
        return launchd_pid(record["label"])
    if mechanism in ("screen", "tmux"):
        listing = run_capture(
            ["screen", "-ls"] if mechanism == "screen" else ["tmux", "ls"]
        )
        return record.get("pid") if listing and record["session"] in listing else None
    pid = record.get("pid")
    return pid if pid and pid_alive(pid) else None


def describe(record):
    pid = running_pid(record)
    port = record.get("port")
    state = "running" if pid else "not running"
    if port:
        state += f", port {port} {'answers' if port_answers(port) else 'silent'}"
    pid_text = f"pid {pid}" if pid else "no pid"
    return (
        f"{record['name']}: {state} ({record.get('mechanism')}, {pid_text})\n"
        f"  cmd: {record.get('cmd')}\n"
        f"  dir: {record.get('dir')}\n"
        f"  log: {record.get('log')}"
    )


def cmd_start(args):
    directory = Path(args.dir or os.getcwd()).expanduser()
    if not directory.is_dir():
        print(f"no such directory: {directory}", file=sys.stderr)
        return 1
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log = log_path(args.name)
    # A restart starts a fresh log, so the tail below can't quote the last run's
    # boot lines as if they were this one's.
    existing = load_record(args.name)
    if existing:
        stop_record(existing)
    log.write_text("")

    started = (
        start_launchd(args.name, directory, args.cmd, log)
        or start_multiplexer(args.name, directory, args.cmd, log)
    )
    unsupervised = started is None
    if unsupervised:
        started = start_detached(args.name, directory, args.cmd, log)

    record = {
        "name": args.name,
        "cmd": args.cmd,
        "dir": str(directory),
        "log": str(log),
        "port": args.port,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        **started,
    }

    deadline = time.time() + max(1.0, args.wait)
    pid = None
    ready = not args.port
    while time.time() < deadline:
        time.sleep(0.3)
        pid = running_pid(record) or pid
        if args.port and port_answers(args.port):
            ready = True
            break
        if pid and not args.port:
            break
    if pid:
        record["pid"] = pid
    save_record(record)

    print(describe(record))
    text = tail(log, 25)
    if text:
        print("--- log ---")
        print(text)
    if unsupervised:
        print(
            "warning: no launchctl/screen/tmux here — started detached, which "
            "may not survive this call",
            file=sys.stderr,
        )
        return 2
    if not ready or not running_pid(record):
        print(
            "the service is not answering — see the log above", file=sys.stderr
        )
        return 1
    return 0


def cmd_status(args):
    if args.name:
        record = load_record(args.name)
        if not record:
            print(f"no service named {args.name}", file=sys.stderr)
            return 1
        print(describe(record))
        return 0 if running_pid(record) else 1

    records = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.is_dir() else []
    if not records:
        print("no services started through this skill")
        return 0
    for path in records:
        record = load_record(path.stem)
        if record:
            print(describe(record))
    return 0


def cmd_logs(args):
    record = load_record(args.name)
    path = Path(record["log"]) if record else log_path(args.name)
    # No service under that name — it may have been a one-shot `run` instead, so
    # look there before telling the agent there is nothing.
    if not path.exists():
        run_log = STATE_DIR / f"{args.name}.run.log"
        if run_log.exists():
            path = run_log
    text = tail(path, max(1, args.lines))
    if not text:
        print(f"no log for {args.name} yet")
        return 0
    print(text)
    return 0


def stop_record(record):
    mechanism = record.get("mechanism")
    if mechanism == "launchd":
        subprocess.run(
            ["launchctl", "remove", record["label"]], capture_output=True
        )
    elif mechanism == "screen":
        subprocess.run(
            ["screen", "-S", record["session"], "-X", "quit"], capture_output=True
        )
    elif mechanism == "tmux":
        subprocess.run(
            ["tmux", "kill-session", "-t", record["session"]], capture_output=True
        )
    pid = record.get("pid")
    if pid and pid_alive(pid):
        # The service may have children (a watcher, a worker); the group goes
        # together so a restart doesn't hit "port already in use".
        try:
            os.killpg(os.getpgid(int(pid)), signal.SIGTERM)
        except OSError:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass


def cmd_stop(args):
    record = load_record(args.name)
    if not record:
        print(f"no service named {args.name}", file=sys.stderr)
        return 1
    stop_record(record)
    time.sleep(0.6)
    still = running_pid(record)
    record.pop("pid", None)
    save_record(record)
    if still:
        print(f"{args.name} is still running (pid {still})", file=sys.stderr)
        return 1
    print(f"{args.name} stopped")
    return 0


def port_holders(port):
    """(pid, command) for every process listening on `port`, via lsof."""
    out = run_capture(
        ["lsof", "-nP", f"-iTCP:{int(port)}", "-sTCP:LISTEN"]
    )
    holders = []
    for line in (out or "").splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1].isdigit():
            holders.append((int(fields[1]), fields[0]))
    return holders


def process_group(pid):
    try:
        return os.getpgid(int(pid))
    except (OSError, TypeError, ValueError):
        return None


def service_for_pid(pid):
    """The service record that owns `pid`, or None when it isn't one of ours.

    Matched by process *group*, not by pid: the command runs under a wrapper
    shell, so the process actually listening on the port is usually that shell's
    child. Comparing pids alone would call our own service a stranger's program
    and refuse to release the port.
    """
    group = process_group(pid)
    if group is None or not STATE_DIR.is_dir():
        return None
    for path in STATE_DIR.glob("*.json"):
        record = load_record(path.stem)
        if not record:
            continue
        ours = running_pid(record)
        if ours and (int(ours) == int(pid) or process_group(ours) == group):
            return record
    return None


def cmd_port(args):
    holders = port_holders(args.port)
    if not holders:
        print(f"port {args.port} is free")
        return 0

    released = []
    for pid, command in holders:
        record = service_for_pid(pid)
        owner = f"service '{record['name']}'" if record else "not started by this skill"
        print(f"port {args.port}: pid {pid} ({command}) — {owner}")
        if not args.release:
            continue
        if not record:
            # Someone else's program. Naming it is help; killing it is not ours
            # to do.
            print(
                f"  left alone — ask the user before touching {command}",
                file=sys.stderr,
            )
            continue
        stop_record(record)
        released.append(record["name"])

    if released:
        time.sleep(0.6)
        still = port_holders(args.port)
        print(f"stopped {', '.join(released)}; port {args.port} "
              f"{'free' if not still else 'still held'}")
        return 0 if not still else 1
    return 1


def cmd_run(args):
    """A long one-shot command under a time limit — the `timeout` macOS lacks."""
    directory = Path(args.dir or os.getcwd()).expanduser()
    if not directory.is_dir():
        print(f"no such directory: {directory}", file=sys.stderr)
        return 1
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log = STATE_DIR / f"{args.name}.run.log"
    log.write_text("")

    started = time.time()
    with open(log, "ab", buffering=0) as handle:
        process = subprocess.Popen(
            ["/bin/sh", "-c", shell_line(directory, args.cmd)],
            stdout=handle,
            stderr=handle,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            cwd=str(directory),
        )
        try:
            code = process.wait(timeout=max(1.0, args.timeout))
            timed_out = False
        except subprocess.TimeoutExpired:
            timed_out = True
            code = None
            # The whole group: a build spawns children, and leaving them behind
            # is how the next run meets "port already in use".
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                time.sleep(0.5)
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except OSError:
                process.kill()

    elapsed = round(time.time() - started, 1)
    verdict = (
        f"timed out after {elapsed}s (killed)"
        if timed_out
        else f"exit {code} in {elapsed}s"
    )
    print(f"{args.name}: {verdict}")
    print(f"  cmd: {args.cmd}")
    print(f"  log: {log}")
    text = tail(log, max(1, args.lines))
    if text:
        print("--- output ---")
        print(text)
    return 0 if code == 0 else 1


def main():
    parser = argparse.ArgumentParser(description="Run a service that outlives a tool call.")
    subs = parser.add_subparsers(dest="command", required=True)

    start = subs.add_parser("start", help="start (or restart) a service")
    start.add_argument("name")
    start.add_argument("--dir", help="absolute project dir (default: cwd)")
    start.add_argument("--cmd", required=True, help='one shell string, e.g. "npm run dev"')
    start.add_argument("--port", type=int, help="wait until this port answers")
    start.add_argument("--wait", type=float, default=6.0, help="seconds to wait")
    start.set_defaults(func=cmd_start)

    status = subs.add_parser("status", help="what is running")
    status.add_argument("name", nargs="?")
    status.set_defaults(func=cmd_status)

    logs = subs.add_parser("logs", help="tail a service's log")
    logs.add_argument("name")
    logs.add_argument("-n", "--lines", type=int, default=80)
    logs.set_defaults(func=cmd_logs)

    stop = subs.add_parser("stop", help="stop a service")
    stop.add_argument("name")
    stop.set_defaults(func=cmd_stop)

    port = subs.add_parser("port", help="who is holding a port")
    port.add_argument("port", type=int)
    port.add_argument(
        "--release",
        action="store_true",
        help="stop the holder, but only if this skill started it",
    )
    port.set_defaults(func=cmd_port)

    run = subs.add_parser("run", help="a long one-shot command, time-limited")
    run.add_argument("name")
    run.add_argument("--cmd", required=True, help='one shell string, e.g. "npm install"')
    run.add_argument("--dir", help="absolute dir to run in (default: cwd)")
    run.add_argument("--timeout", type=float, default=300.0, help="seconds")
    run.add_argument("-n", "--lines", type=int, default=40)
    run.set_defaults(func=cmd_run)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
''';
