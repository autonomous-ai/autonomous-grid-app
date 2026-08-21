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
///
/// It names that moment by *intent*, never by example phrases. A card that
/// listed "keep checking" and "mỗi sáng 8h" covered exactly the two languages
/// somebody happened to type, and every user writing in a third one fell
/// through — the same failure as the phrase-matching this replaced, moved one
/// layer up. The model reads meaning; describe the meaning and let it.
const String kGridLoopSkillMd = '''
---
name: grid-loop
description: >-
  Repeating, continuing and scheduled work in Grid's chat. Use whenever the
  user asks you to keep doing something, to carry on until some condition is
  true, to run at a clock time or on a repeating schedule, or to stop or drop
  one of those — in whatever language they wrote it in, however indirectly they
  put it, and whether or not they name a command. It is the intent that
  decides, never a list of trigger words. Grid owns those jobs; this says how
  to ask it for one, in the same reply you answer them in. Also use when the
  message you are answering asks for a `grid-loop` block, to pace a loop that
  is already running.
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

## When the user asks for something the app owns

Grid runs a command the user **typed** with a slash — `/loop 30m …`, `/goal …`,
`/schedule …`. It does not try to read one out of an ordinary sentence: no list
of phrases covers every way a person asks in one language, let alone in all of
them, and the list that lived here read "redo the header for me" as a request
to loop.

So that reading is yours. You have the sentence in front of you; when it is
asking for one of these, **say so with a `grid-ask` block** and Grid runs it:

```grid-ask
{"run": "/loop 45m look for new sources, report the ones worth adding"}
```

Three commands can be asked for this way, and nothing else — starting
something, and ending it:

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

Rules, and they are what make this worth trusting rather than a way to keep
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
''';
