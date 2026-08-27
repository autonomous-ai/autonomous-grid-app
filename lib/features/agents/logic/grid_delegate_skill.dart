import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that keeps a delegated sub-agent inside the turn that spawned it.
///
/// Grid runs a turn as one process and closes it when the reply ends, so an
/// agent still working when the reply lands is killed mid-tool-call and the
/// report it owed never arrives. Neither spawner can see that from the inside:
/// Claude Code's launch result says in so many words that a notification is
/// coming, and Codex's agents outlive nothing but believe they might.
///
/// Two spawners, two different mistakes, one card — because the fact underneath
/// is the same one, and splitting it would leave each half free to drift from
/// the truth it shares.
///
/// **For Codex this card is also the permission.** Its base instructions forbid
/// spawning "unless the user or applicable AGENTS.md/skill instructions
/// explicitly ask", so installing this is what turns delegation on for it —
/// which is why it says when to spawn as carefully as it says how to wait.
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
  farming out a search or a review, or anything that would otherwise run while
  you carry on. Read this before the first spawn. In Grid a turn is a process
  that ends with your reply, so a sub-agent still running when you finish is
  killed mid-sentence and the report you were promised never arrives. This is
  when delegating is worth it here, and how to keep the parallelism without the
  promise that cannot be kept.
---

# Sub-agents run in front of your answer, never behind it

A Grid turn is one process. The app opens it to answer this message and closes
it the moment your reply is complete. Everything you started is inside that
process, so everything you started dies with it.

Measured here on 2026-08-21, to the millisecond: two sub-agents were resumed,
worked for ninety seconds, and their transcripts stop at `07:48:00.461Z` — one
millisecond before the final text of the reply at `07:48:00.462Z`, both of them
in the middle of a tool call. The reply said "I have resumed the two scout
agents and am waiting for them to report back". No report existed, none was
coming, and the user asked "done yet?" into a chat where nothing was running.

## When it is worth spawning at all

Delegate when the work genuinely splits — several areas to map, a list of files
to review, searches that do not depend on each other — and the answer arrives
sooner or better for it. Not for a job one pass would finish: a spawn costs a
model, a context and a wait, and three files read here beat six agents that
report after the turn is over.

Only for the turn you are in. Never spawn something whose value arrives later.

## If your spawner runs them in the background — Claude Code

Its launch result will tell you the agent is working in the background and that
you will be notified automatically when it completes. That is true of a session
that stays open. **It is not true here**, and there is no way to tell from the
inside — which is why this card exists.

- **Spawn with `run_in_background: false`, every time.** The agent runs in front
  of you and you get its report inside this turn.
- **Parallel still works.** Send several spawns as separate tool calls in one
  message; they run at the same time and all report back before you carry on.
- **Resuming one from an earlier turn does not bring it back to life.** The
  resume genuinely succeeds, and then that agent dies with *this* reply exactly
  as it did with the last one. If you resume, wait for it here.

## If your spawner makes you wait for them — Codex

You have `multi_agent_v1`: `spawn_agent`, `wait`, `send_message`,
`followup_task`, `interrupt_agent`, `close_agent`, `resume_agent`,
`list_agents`, `spawn_agents_on_csv`. Your base rules say not to spawn unless
the user, AGENTS.md or a skill explicitly asks — **this card is that ask**, on
the terms above and no others.

- **Never end a turn holding an agent you have not waited on.** `wait` is the
  whole contract; nothing arrives without it.
- **`wait` returns on the first agent to finish**, so waiting on three ids is
  not waiting for three agents. Call it again until every id has reached a final
  status, and treat its timeout flags as "still running", never as "done".
- **`close_agent` when you are finished with one.** A completed agent stays open
  and counts against the concurrency limit until closed — leave enough of them
  behind and the next turn cannot spawn at all.
- **`send_message` queues without starting a turn; `followup_task` starts one.**
  If you need more work out of an agent, the second is the one that gets it.
- **`spawn_agents_on_csv` blocks until every row finishes** — it is the safe
  shape by construction. Its cap is 16 workers at a time.
- Stopping early is `interrupt_agent` then `close_agent`. Abandoning is neither.

## Whichever you are

- **Never end a reply while something you started is still going.** If you are
  not holding the report, you do not have it — and neither will anyone else.
- **Doing it yourself beats promising it.**

## Never write these

- "I have started N agents and will report when they come back."
- "The scouts are running in the background; I will summarise once they finish."
- "Waiting for the sub-agent to report."

There is no later. Whatever the user is told will be true of a chat where
nothing is running, and the next thing they do is ask why it went quiet.

If a job really is too big for one turn, say so, and say what the next turn
should pick up — the user decides whether to send it.
''';
