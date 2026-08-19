import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that points every agent at the one scheduler this computer has.
///
/// An agent asked to repeat something reaches for whatever scheduler its own
/// vendor gave it, and in Grid every one of those is a trap: a turn here is a
/// process the app starts for one answer and stops when the answer ends, so a
/// job held in that process's memory is gone seconds after the agent reports it
/// scheduled. Claude Code's session cron did exactly that on 2026-08-19 — two
/// jobs created at 16:07, both dead by 16:07:16, the user told they would run
/// every 30 minutes for seven days.
///
/// Hermes's scheduler is the opposite: a daemon with a store on disk that
/// outlives the app, and the one the Scheduled screen reads. So the fix is to
/// tell every agent it exists, and that its own does not work here.
const String kGridScheduleSkillName = 'grid-schedule';

/// The `grid-schedule` skill as it lands in [skillDir]. Card only — the CLI it
/// drives is already installed — but it takes the directory like every other
/// builtin so the registry can treat them alike.
GridSkillFiles gridScheduleSkillFiles(Directory skillDir) =>
    const GridSkillFiles(card: kGridScheduleSkillMd);

/// The card. The front-matter names what the user asks for ("every morning",
/// "keep checking") rather than the CLI, because the agent meets this while
/// being asked for a repeating task — it does not yet know a `hermes cron`
/// exists, which is the whole reason it needs the card.
const String kGridScheduleSkillMd = '''
---
name: grid-schedule
description: >-
  Set up work that runs later or over and over — every morning, every 30
  minutes, once tonight, a watcher that keeps checking something. Use whenever
  the user asks for a scheduled, recurring or automatic task, says "every N
  minutes", "each morning", "remind me at", or wants something to keep running
  after this conversation ends. Also use to list, pause, run now, or delete
  tasks that are already scheduled.
---

# Scheduling work on this computer

**Your own scheduler does not work here.** Whatever your runtime offers for
timers, cron or reminders keeps the job in the memory of the process answering
this turn — and Grid starts that process for one answer and stops it when the
answer ends. A job scheduled that way is gone within seconds, after you have
already told the user it will run for days. Never use it, and never tell the
user a task is scheduled because you called it.

This computer has one real scheduler: a background daemon that keeps running
after the app is closed, with its jobs written to disk. Everything below drives
it. Jobs you create show up in the app's **Scheduled** screen, and each run's
answer is delivered back into the app.

The command is `hermes`. If the shell cannot find it, use
`~/.grid/bin/hermes` — Grid installs it there.

## Create a job

```
hermes cron create "<schedule>" "<prompt>" --name "<short name>" \\
  --deliver "grid:chat:\$GRID_CHAT_ID" --workdir "<absolute dir>"
```

`\$GRID_CHAT_ID` is set for you: it is the chat you are answering in.

- **schedule** — `30m`, `every 2h`, or a 5-field cron expression
  (`7,37 8-22 * * *`). Cron fields are in this computer's own timezone; don't
  convert.
- **prompt** — self-contained. The run starts with none of this conversation:
  no files you just read, no paths you worked out, no "as we discussed". Write
  out the steps, the absolute paths, and what to do when there is nothing to
  report.
- **--deliver** — where the answer is put. **`grid:chat:\$GRID_CHAT_ID`** when
  you are scheduling something a user asked for in a conversation: it puts each
  run's answer in *this* chat, under their question, which is where they will
  look for it. `grid:project:<project id>` files it under a project. Plain
  `local` gives the task a thread of its own — right for a standing digest
  nobody asked for in a conversation, wrong for everything else. Never leave it
  out.
- **--workdir** — absolute directory the job runs from.
- **--repeat N** — stop after N runs. Leave it out to run until removed.
- **--skill <name>** — attach a skill the job needs. Repeat for several.

## Which assistant the job runs as — say it, don't assume it

A plain job like the one above is run by **the scheduler's own assistant**, not
by you. Different tools, different skills, its own model. For "check the news
each morning" nobody cares. For work that needs what *you* have — this repo's
files, a browser you drove, a tool only you were given — a job that answers as
somebody else is a quiet substitution, so **tell the user which one will run
it** whenever you schedule anything.

To keep the work with the assistant the user is talking to, schedule a script
instead and let it call that assistant:

```
~/.hermes/scripts/<name>.sh          # the script (chmod +x)
hermes cron create "<schedule>" --script <name>.sh --no-agent \\
  --name "<short name>" --deliver local
```

`--no-agent` means the script *is* the job and its stdout is delivered
verbatim — so print the answer and nothing else. Three things the script must
do itself, each measured on 2026-08-19 rather than assumed:

- **`cd` to where the work is.** In script mode the job starts in
  `~/.hermes/scripts`, and `--workdir` does not move it.
- **Set `PATH` with absolute directories.** The scheduler is a daemon; it has
  none of the login shell's PATH, so `claude` / `codex` / `node` are not found
  unless the script names their folders.
- **Grant the tools the run needs.** `claude -p "…" --allowedTools Bash Read
  Write` — headless, anything not allowed is refused mid-run rather than
  asked about. Codex's equivalent is `codex exec "…"`.

## Read it back before you answer

A job you did not read back is not a job. Every time:

```
hermes cron list
```

Only after the job appears there do you tell the user it is scheduled — and
tell them the next run time the list prints, not the one you intended.

## Check that it really runs

```
hermes cron run <id>     # queue one run on the next tick
hermes cron runs <id>    # what the runs actually did
```

When a user doubts a scheduled task, `runs` is the answer — it is the record of
attempts, not a rewording of what the schedule was supposed to do.

## Manage

```
hermes cron pause <id>
hermes cron resume <id>
hermes cron remove <id>
```

## Rules

- **Pick an off-minute** when the user's time is approximate: "hourly" →
  `7 * * * *`, "every morning around 9" → `57 8 * * *`. Use `0` or `30` only
  when they named that exact minute.
- **A window is hours, not a second job.** "Every 30 minutes from 8:00 to
  23:00" is `7,37 8-22 * * *` plus one entry for the last slot — say plainly
  which slots that covers instead of implying the window is continuous.
- **No `hermes` on this machine** means the scheduler isn't installed. Say so,
  and stop. Falling back to your own timer is worse than not scheduling: it
  looks like it worked.
''';
