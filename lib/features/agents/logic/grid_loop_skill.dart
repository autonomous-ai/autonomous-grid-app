import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that tells an agent it is the one pacing a repeating task.
///
/// Grid's `/loop` re-runs a prompt on its own. Without an interval it is
/// *self-paced*, which used to mean the app asked a second model — one that had
/// never seen the turn — how many minutes to wait, and had no way at all to be
/// told the job was finished. This is the format that lets the assistant which
/// actually did the work answer both questions itself.
///
/// No scripts: the whole skill is a card. The agent already knows what it just
/// found by the time this matters; what it needs is where to put the answer.
const String kGridLoopSkillName = 'grid-loop';

/// The `grid-loop` skill as it lands in [skillDir]. Takes the directory like
/// every other builtin so the registry can treat them alike, though this one has
/// nothing on disk to point at.
GridSkillFiles gridLoopSkillFiles(Directory skillDir) =>
    const GridSkillFiles(card: kGridLoopSkillMd);

/// The card. The front-matter names the moment rather than the fence: the agent
/// meets this while answering a task it is being asked to repeat, and "how long
/// until I should look again" is the question it has, not "what is a
/// `grid-loop` block".
const String kGridLoopSkillMd = '''
---
name: grid-loop
description: >-
  Decide when a repeating task in Grid's chat should run again, and when it
  should stop. Use whenever the message you are answering asks for a
  `grid-loop` block — a task on a loop, watching a deploy, a build, a PR, an
  inbox — to say how long to wait before the next check, that nothing changed,
  or that the job is finished and the loop can end.
---

# Pacing a repeating task

Grid re-runs some prompts on their own. When the message you are answering ends
with a request for a `grid-loop` block, the app is waiting on you for one
decision: **what should happen after this answer.** Nothing else in the app can
make it — you are the only one who has seen what this check found.

Answer the question first, in full, exactly as you would normally. Then put the
block last, after your answer.

## The format

A `grid-loop` fence holding one JSON object. Three things it can say:

```grid-loop
{"next": "20m", "why": "the build has about 15 minutes left"}
```

```grid-loop
{"quiet": true, "next": "1h", "why": "nothing has moved since the last check"}
```

```grid-loop
{"stop": true, "why": "the deploy finished and the smoke tests passed"}
```

- `next` — how long to wait before running this again, as `45s`, `20m`, `2h`.
  Under a minute is rounded up to one; over an hour is capped at one. Leave it
  out on a task whose interval the user set themselves — you cannot change that
  one, only end it.
- `why` — one short line, shown to the user on the loop bar. Say what you are
  waiting *for*, not that you are waiting.
- `quiet` — `true` when this run found nothing new. The app collapses a run of
  them, so a night of "still building" reads as a count instead of forty
  identical answers.
- `stop` — `true` when there is nothing left to check. This is how a finished
  job ends: the loop stops, and the user is told why.

## Rules

- **Stopping is normal, not a failure.** A loop watching a deploy is done when
  the deploy is done. Leaving it running until somebody notices wastes their
  machine and their grid; say `stop` and say why.
- **Pace it by what you saw.** Something actively changing deserves minutes;
  something that will not move before morning deserves an hour. A gap picked
  without a reason is the app's ten-minute default with extra steps.
- **One block, at the very end.** The last one in the reply is the one that
  counts, and it is taken back out before anyone reads the answer — so never
  put anything in it you meant the user to see.
- **Leave it out to carry on unchanged.** No block is not an error: the loop
  keeps its own pace. Use that when you genuinely have nothing to add.
- **Never stop because the task was hard.** A failed check is a reason to look
  again, not a reason to end. Stop only when the thing being watched has
  actually finished.

## The block cannot start a loop

It is read in one place only: at the end of a beat of a loop that is **already
running**. In any other reply it is text nobody reads — the app does not scan
ordinary answers for it. So when you are asked to set a repeating task up:

- **Never write the block to create one, and never say you have.** "I've set a
  `grid-loop` to re-run every hour" is a promise nothing behind it keeps, and
  the user finds out in the morning, from a task that ran once.
- **A loop for this chat** is the user typing `/loop <what to repeat>` in the
  composer — say that, in those words. It runs while Grid is open.
- **Work that has to survive the app closing** — overnight, tomorrow morning,
  every 30 minutes all week — is not a loop at all. Schedule it with the
  `grid-schedule` skill, which writes to a daemon that keeps running.
''';
