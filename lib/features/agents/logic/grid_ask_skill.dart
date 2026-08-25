import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that tells an agent how to hand Grid a job that outlives the turn.
///
/// Split out of `grid-loop` on 2026-08-21, and the split is the whole point: a
/// card is retrieved on its name and description, so one called `grid-loop`
/// answered a message about looping and stayed shut for the goal and the
/// scheduled task filed under the same rules. This one is named after the
/// question it settles — *what is the user asking Grid to do* — because that
/// question is worth asking of every message, not of the ones with "loop" in
/// them.
const String kGridAskSkillName = 'grid-ask';

/// The `grid-ask` skill as it lands in [skillDir]. Card only, like `grid-loop`:
/// nothing to run, only a format to know about.
GridSkillFiles gridAskSkillFiles(Directory skillDir) =>
    const GridSkillFiles(card: kGridAskSkillMd);

/// The card. The front-matter describes the *intent* to look for and never an
/// example phrase: a list of them covers exactly the languages it was written
/// in, which is the phrase-matching this replaced wearing a different hat.
const String kGridAskSkillMd = '''
---
name: grid-ask
description: >-
  What the user is asking Grid itself to do — worth checking against every
  message before you answer it. Work that should be repeated, carried on until
  some condition is true, run at a clock time or on a recurring schedule, or
  one of those the user now wants stopped or dropped: in whatever language they
  wrote it in, however indirectly they put it, and whether or not they name a
  command. It is the intent that decides, never a list of trigger words. Grid
  owns all of those, none of them survive the turn you are answering in, and
  this is the one way to hand one over.
---

# Asking Grid for work that outlives this turn

Whatever your runtime gives you for timers, cron, reminders or loops keeps the
job inside the process answering this message — and Grid closes that process
when your reply ends. Anything you set up there is gone before the user finishes
reading the sentence that says you set it up. That is not a warning about a
corner case: it is what happens every time.

Grid keeps the jobs that have to outlive a turn. It starts them from a command
the user **typed** with a slash — `/loop 30m …`, `/goal …`, `/schedule …` — and
it does not try to read one out of an ordinary sentence: no list of phrases
covers every way a person asks in one language, let alone in all of them, and
the list that used to try read "redo the header for me" as a request to loop.

So that reading is yours. You have the sentence in front of you; when it is
asking for one of these, **say so with a `grid-ask` block** and Grid runs it:

```grid-ask
{"run": "/loop 45m look for new sources, report the ones worth adding"}
```

## What can be asked for

Five things, and nothing else — three that start work, two that end it:

| The user is asking for | Write |
|---|---|
| this done again and again while Grid is open, with no finish line named | `/loop <gap> <what to repeat>` |
| you to keep at it **until some condition holds** — and then be done | `/goal <what has to be true>` |
| work at a clock time, or on a cadence that must outlive Grid being closed | `/schedule <when> <what>` |
| a repeat that is running to **stop** | `/loop stop` |
| a goal that is set to be **dropped** | `/goal clear` |

The left column is the shape of the request, not its wording. Match on what
they want to happen; the words that carry it differ in every language, and in
every person.

## Rules

These are what make the block worth trusting, rather than a way to keep
yourself running:

- **Answer them *and* write the block.** These are not alternatives. On
  2026-08-21 "mục tiêu của mày là làm performance cho repo này" got twenty-five
  minutes of real work and no block, so the goal was never set and the work
  stopped when the turn did — which is the opposite of what a goal is for. Do
  the work, then relay the ask at the end of the same reply.
- **Only when the user asked for it.** Deciding by yourself that a job deserves
  repeating is not that, and it spends someone's tokens all night.
- **Read the sentence, not the words in it.** Someone *describing* a job that
  runs till morning is not asking you to run till morning; someone *asking* you
  to keep going till then is. Someone asking **how** to stop a loop wants an
  answer, not a stop. Every language carries both readings with the same words,
  so what settles it is who is being asked to do what — never which words
  turned up.
- **Any language, any script.** People write here in Vietnamese, English,
  Chinese, or a mix inside one sentence, and none of that changes what you are
  reading for. You translate the intent: the command line you put in the block
  is always the app's own English one, while the prompt inside it stays in
  their words and their language, because that is what gets re-run.
- **Stopping is the one to be quick about.** A repeat the user has asked to end
  keeps costing them until the block lands, so put it in the reply that answers
  them, not the one after.
- **Their words, not yours.** The prompt you write is what gets re-run or
  scheduled, so it has to say what *they* asked for.
- **Name the gap and the time.** `/loop` with no gap paces itself, which is
  fine; `/schedule` with no hour fires at one nobody chose, which is not.
- **One block, at the end, and nothing else claimed.** Don't also write "I've
  set a grid-loop to re-run every hour" — either the block, or tell them to
  type the command themselves. A reply that claims a repeat without the block
  gets a note under it saying nothing is repeating.

Grid tells you what it did: a loop gets a bar in the chat, a goal gets its own,
a scheduled task gets a row in **Scheduled**. All three the user can stop.

Two neighbours, so you don't do a job twice:

- Once a loop is running, Grid asks *you* how long to wait before each next
  run. That is a different block and a different card — `grid-loop`.
- This card **starts and stops**. Listing scheduled tasks, pausing one, running
  one now or deleting one is `grid-schedule`, which drives the scheduler
  directly. Creating one from a message you are answering belongs here: the
  relay wires the answers back into this chat, which the raw command makes you
  do by hand.
''';
