import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';
import 'grid_serve_skill.dart';

/// The skill that tells an agent what this computer actually has, before it
/// spends a tool call finding out.
///
/// Read off 83 recorded Codex turns: `timeout` was reached for 30 times, `gh` 18,
/// `rg` 7 — none of the three exist on a stock macOS box, so every one of those
/// calls was thrown away, and the model then improvised something worse. This
/// card is deliberately written as *check, then substitute* rather than a fixed
/// inventory: the moment the user installs `gh`, a hardcoded "you don't have gh"
/// would be the new lie.
const String kGridHostSkillName = 'grid-host';

/// The `grid-host` skill: one card, no scripts — there is nothing to run, only
/// something to know.
GridSkillFiles gridHostSkillFiles(Directory skillDir, {String? uvPath}) =>
    GridSkillFiles(card: gridHostSkillMd(uvPath: uvPath ?? gridSkillUvPath()));

/// The card every agent reads.
///
/// The frontmatter has to fire *before* the mistake, so it triggers on the intent
/// ("about to use `timeout`", "about to install something") as well as on the
/// aftermath ("command not found") — a card that only fires after the failure
/// saves nothing.
String gridHostSkillMd({required String uvPath}) =>
    '''
---
name: $kGridHostSkillName
description: What this computer has installed, and what to use instead when something is missing — check here before reaching for timeout, gh, rg, setsid, tmux, a system python, or any installer. Use whenever a command comes back "command not found", when you need a time limit on a command, and before you install anything.
tags: [environment, tooling, macos, path, grid]
triggers:
  - a command failed with "command not found"
  - you are about to use timeout / gtimeout, gh, rg, setsid, tmux
  - you are about to install something (brew install, npm -g, pip install)
  - you need to run a command with a time limit, or in the background
  - "sao lệnh này không chạy", "cài giúp tao", "máy có sẵn gì"
---

# This computer, before you guess

This is **macOS**, not a Linux box, and it has no GNU coreutils. Several tools
you would normally reach for are simply absent — a call spent discovering that is
a call wasted, and the improvisation that follows is usually worse than the
substitute below.

**Rule: check, don't assume.**
```
command -v <tool> >/dev/null || echo "<tool> is missing"
```

## What to use instead

| You want | Not here | Do this |
|---|---|---|
| A time limit on a command | `timeout`, `gtimeout` | the `$kGridServeSkillName` skill's `run` — it bounds the command and hands you the log |
| GitHub (PRs, issues, releases) | `gh` | `git` for anything local — check it first, see below; for the API, `curl` with the user's token — ask for one if there is none |
| Fast recursive search | `rg` (ripgrep) | `grep -rn --include="*.dart" "<pattern>" <dir>` |
| Detach a process | `setsid`, `tmux` | the `$kGridServeSkillName` skill (`screen` exists, but let the skill drive it) |
| Run Python, or a Python package | a dependable system `python3` | `"$uvPath" run --no-project python3 …`, and `--with <pkg>` for a dependency — nothing is installed globally |

## What is here
The one thing that is certain is the grid CLI's pinned `uv` at `$uvPath` — Grid
installs it, so it is always there.

`curl`, `lsof`, `screen`, `launchctl`, `zsh`, `perl`, `sed` and `awk` ship with
macOS. `git`, `jq` and Homebrew (`/opt/homebrew/bin/brew` on Apple Silicon)
usually exist but are **not** guaranteed — the rule above applies to them, and to
anything else you are about to reach for:

```
command -v git >/dev/null || echo "git is missing"
```

**`git` in particular**: on a Mac, `/usr/bin/git` exists even when Git does not.
It is a stub that asks to install Apple's developer tools, so `ls /usr/bin/git`
and `command -v git` both succeed on a machine where Git cannot run — and running
it can pop an installer dialog in the user's face. The only check that means
anything is `git --version`. If that fails, say so and stop; do not try to
install Git yourself (see below).

`node`, `npm`, `npx` and `pnpm` come from **nvm** (`~/.nvm/versions/node/<v>/bin`)
— they exist only while that folder is on `PATH`. So:
- Inside your own shell: fine, they resolve.
- Anything that runs *outside* it — a launchd job, a cron entry, a plist — gets a
  minimal environment and will fail with "node: command not found" unless the
  `PATH` travels with it. The `$kGridServeSkillName` skill already does that for
  you; if you write your own job, use the absolute path from `command -v node`.

## Installing things

**Never install unattended.** No `brew install`, `npm -g`, `pip install`,
`softwareupdate`, and never `sudo` — this is the user's machine, and an install
they didn't ask for is not yours to make. If a tool is genuinely needed:

1. Check whether you can do the job without it (the table above usually says yes).
2. For a one-off Python dependency, don't install at all — `"$uvPath" run --with
   <pkg>` fetches it into a cache and leaves the machine untouched.
3. Otherwise **ask the user**, name the exact command and why, and wait.

## If something still won't run
Say what you tried, what the shell answered, and which substitute you fell back
to. "It didn't work" costs the user a round trip; "`timeout` isn't on macOS, so I
bounded it with $kGridServeSkillName `run` instead" doesn't.
''';
