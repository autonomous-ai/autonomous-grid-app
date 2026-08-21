import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that keeps a delegated sub-agent inside the turn that spawned it.
///
/// Grid runs a turn as one `claude -p` process and closes it when the reply
/// ends, so a sub-agent launched in the background is killed mid-tool-call and
/// the notification it was promised never comes. The agent has no way to know
/// that from the inside: the launch result tells it, in those words, that it
/// will be notified automatically.
///
/// Fourth of the same bug — after `CronCreate`, `ScheduleWakeup` and a
/// persistent `Monitor`, all of which the app now refuses outright. This one is
/// not refused, because delegation itself is worth having; what it needs is to
/// happen in front of the reply rather than behind it.
const String kGridDelegateSkillName = 'grid-delegate';

/// The `grid-delegate` skill as it lands in [skillDir]. Card only.
GridSkillFiles gridDelegateSkillFiles(Directory skillDir) =>
    const GridSkillFiles(card: kGridDelegateSkillMd);

/// The card. Named for the moment before the first spawn, because after it the
/// damage is done: the work runs, the turn ends, and the answer is a promise.
const String kGridDelegateSkillMd = '''
---
name: grid-delegate
description: >-
  Handing part of a job to sub-agents — exploring several areas at once,
  farming out a search or a review, or anything that would otherwise run in the
  background while you carry on. Read this before the first spawn. In Grid a
  turn is a process that ends with your reply, so a sub-agent still running
  when you finish is killed mid-sentence and the report you were promised never
  arrives. This is how to keep the delegation and the parallelism without the
  promise that cannot be kept.
---

# Sub-agents run in front of your answer, never behind it

A Grid turn is one process. The app opens it to answer this message and closes
it the moment your reply is complete. Everything you started is inside that
process, so everything you started dies with it.

Measured here on 2026-08-21, to the millisecond: two `Explore` agents were
resumed, worked for ninety seconds, and their transcripts stop at
`07:48:00.461Z` — one millisecond before the final text of the reply at
`07:48:00.462Z`, both of them in the middle of a tool call. The reply said "I
have resumed the two scout agents and am waiting for them to report back". No
report existed, none was coming, and the user asked "done yet?" into a chat
where nothing was running.

**The launch result will tell you otherwise.** It says the agent is working in
the background and that you will be notified automatically when it completes.
That is true of a session that stays open. It is not true here, and there is no
way to tell from the inside — which is why this card exists.

## The rule

**Spawn with `run_in_background: false`, every time.** The agent then runs in
front of you: you get its report inside this turn, and you can use it in the
answer you are about to write. That is the whole fix.

- **Parallel still works.** Send several spawns as separate tool calls in one
  message and they run at the same time; you get all of the reports back before
  you carry on. Waiting is not the same as doing them one after another.
- **Never end a reply while something you started is still going.** If you are
  not holding the report, you do not have it — and neither will anyone else.
- **Resuming one from an earlier turn does not bring it back to life.** The
  resume genuinely succeeds, and then that agent runs *in this process* and
  dies with *this* reply, exactly like the first time. If you resume, wait for
  it here.
- **Doing it yourself beats promising it.** Three files read in this turn are
  worth more than six agents that will be killed before they answer.

## Never write these

- "I have started N agents and will report when they come back."
- "The scouts are running in the background; I will summarise once they finish."
- "Waiting for the sub-agent to report."

There is no later. Whatever the user is told will be true of a chat where
nothing is running, and the next thing they do is ask why it went quiet.

If a job really is too big for one turn, say so and hand it to Grid instead —
`/loop` or `/goal` re-run *whole turns*, which is the only thing here that does
survive one. The `grid-ask` card is how to ask for that.
''';
