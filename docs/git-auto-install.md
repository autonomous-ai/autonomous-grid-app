# Git, installed in the background

The app needs a Git it can run, and until now it neither installed one nor
checked for one. This covers what was built, and the two things about Git that
make it unlike every other tool the app installs.

## Why the app needs Git

| Where | What breaks without it | Platform |
|---|---|---|
| `hermes_plugin_service.dart:48` → Hermes `plugins_cmd.py` | "Add from Git" clones a repo. Hermes refuses with `git is not installed or not in PATH.` | all |
| `host_environment.dart` `gitBash()` → `HERMES_GIT_BASH_PATH` | Hermes runs **every** command through Git Bash. Without it, it falls back to the WSL stub and every terminal step fails; `write_file` fails with an empty error | **Windows** |
| `grid_host_skill.dart` | The skill card told the agent Git was here, unconditionally. The agent believed it and improvised — no error anywhere | all |

Not affected, and checked: Codex passes `--skip-git-repo-check`, agent undo keeps
its own before/after copies, and the app never clones anything itself.

## What it does

One background pass, started from `home_shell.dart` beside the agent installer.
Nobody is asked, nothing is blocked, a failure is a log line
(`BackgroundGitInstaller`).

```
probe ──┬─ a Git that runs      → adopt it, install nothing
        ├─ a Git that's too old → install ours beside it (logged loudly)
        └─ none                 → download, verify, unpack, re-probe, adopt
```

**A Git the user already has always wins.** Git carries their credential helper,
`http.proxy` and `sslCAInfo`; a copy of ours in front of theirs would break
cloning a private repository in a way that looks like our bug. Ours only ever
fills a gap — which is what makes it safe for `_buildPath()` to put it early.

Both the background pass and the button on the Git screen install through
`GitInstallController`. One path, for two reasons: the two write the same tree
under `~/.grid`, so a button pressed mid-download would have raced the swap into
a half-moved directory — and sharing the state is what lets the screen show a
background install as it happens, and still hold the reason when one failed an
hour before anyone looked.

## Where the user sees it

**Settings ▸ Coding ▸ Git** (`features/git/presentation/git_view.dart`). One
card, saying which Git is being run and from where. Its four states are the
probe's, not a bool — "there's a file but it doesn't work" reads differently
from "install Git", which is the whole point of `GitStatus`.

| State | What it offers |
|---|---|
| Grid's own copy, or the user's | *Check again* — a Git can be upgraded or moved out from under us |
| Too old | *Install Git*, which goes in beside theirs rather than over it |
| None, platform supported | *Install Git* — the background pass either failed or hasn't finished |
| None, no build for this platform | `GitMissingNotice`: the install command for this OS, with a copy button |

Nobody should need it: Git lands in the background at first launch. It exists
for the machine where that didn't happen, and it is the only place an install
that failed hours ago was ever going to be read.

The section is its own group rather than a row under Personal because Git is the
first of a set that belongs together — branch switching, a worktree per parallel
agent, reviewing a project's diff. The screen says nothing about those: they
aren't built, and listing them would be a promise.

## The macOS trap

`/usr/bin/git` exists on **every** Mac, including one where Git cannot run. It is
one of 78 hard links to the same `xcode-select` stub (`clang`, `make`, `python3`
are others), 118 KB, linked only against `libxcselect`.

Two consequences, both load-bearing:

1. **Existence proves nothing.** `File('/usr/bin/git').existsSync()` is `true` on a
   machine with no Git at all, so `HostEnvironment.findExecutable('git')` cannot
   be used to decide this. The probe runs `git --version` and requires the output
   to start with `git version`.
2. **Running it is not free.** On a Mac without the Command Line Tools, the stub
   pops Apple's installer dialog over whatever the user was doing — a *probe*
   would become an *install prompt*. So `probeGit()` never executes anything under
   `/usr/bin`: it resolves the developer directory first (`DEVELOPER_DIR`, else
   `xcode-select -p`, a separate binary that never prompts) and runs the Git
   inside it by absolute path.

Everything else follows from those two facts. `GitStatus` has three cases rather
than a bool for the same reason — "a file is there but it doesn't work" is a real
state, and the copy for it differs from "install Git".

## Which build, per platform

| Platform | Asset | Status |
|---|---|---|
| macOS arm64 / x64, Linux x64 / arm64 | `dugite-native` (`git_release_pins.dart`) | shipped |
| Windows | PortableGit | **not built yet** — see below |

`dugite-native` is the Git that GitHub Desktop embeds: built to be unpacked
anywhere, published with a `.sha256` per asset, and — measured, not assumed —
ad-hoc signed, so macOS runs it once it is not quarantined.

Two costs, both handled rather than hidden:

- It is **not upstream Git**, and its README says it is not intended for end
  users. The version is pinned hard and bumped by hand.
- It **relocates through the environment, not the binary**. A spawned `git` needs
  `GIT_EXEC_PATH`, `GIT_CONFIG_SYSTEM` and `GIT_TEMPLATE_DIR`
  (`HostEnvironment.gitEnvironment`). Without the first, `git clone` over HTTPS
  dies with `'remote-https' is not a git command`.

### Why Windows is separate work

dugite's Windows build repackages **MinGit**, which has no `bin\bash.exe` — and
that file is exactly what `gitBashBeside()` looks for to fill
`HERMES_GIT_BASH_PATH`. The asset that does carry it is **PortableGit**, a
self-extracting `.7z.exe` that must be run rather than unzipped. Until that
lands, Windows keeps using whatever Git the user installed.

## One thing the unpacker had to learn

`extractArchive` skipped every entry that wasn't a plain file. A single-binary
release has none; a Git tree has **145 symlinks**, one of which is
`git-remote-https -> git-remote-http`. Dropping them produced a Git that answered
`--version` perfectly and failed every HTTPS clone — a lossy unpack wearing the
costume of a broken download.

It now recreates symlinks (refusing absolute targets and any that escape the
destination) and carries the executable bit over. Both apply to every archive the
app unpacks, not just Git's.

## Files

| File | Role |
|---|---|
| `infrastructure/cli/git_probe.dart` | `probeGit()`, `GitStatus`, version gate. **Plain Dart** — no Flutter, so it runs standalone |
| `infrastructure/cli/git_install.dart` | Download → verify → unpack → swap in → confirm it runs. Plain Dart |
| `infrastructure/cli/git_release_pins.dart` | Pinned URL + SHA-256 per platform |
| `infrastructure/cli/git_providers.dart` | The Riverpod wiring plus `adoptGit()`, kept apart so the two above stay framework-free |
| `features/git/logic/background_git_installer.dart` | The one background pass |
| `features/git/logic/git_install_controller.dart` | The only path Git is installed by — single-flight guard, re-probe, adopt |
| `features/git/presentation/git_view.dart` | Settings ▸ Coding ▸ Git |
| `shared/widgets/git_missing_notice.dart` | The per-OS install command, shared by that screen and the Add-a-plugin dialog |
| `infrastructure/cli/host_environment.dart` | `gitEnvironment()`, `adoptGridGit()`, `resetGitBash()`, PATH |

Pins live **outside** `agent_release_pins.dart` on purpose: that file is a
hand-kept copy of the CLI's own installers and its `TODO(BE)` is to fold the two
into one source. Git has no counterpart on the CLI side, so filing it there would
create a pin that can never be synced and would keep that TODO from closing.

### `resetGitBash()` — small, and easy to leave out

`gitBash()` answers once per session and remembers even a `null`, and
`hermesEnvironment()` — the environment behind every `hermes` spawn — reads it.
Installing Git without clearing that cache leaves every later spawn missing
`HERMES_GIT_BASH_PATH`, so the install appears to have done nothing until the app
restarts. Anything that installs or removes Git must call it, and must invalidate
`gitStatusProvider` for the same reason.

## Bumping the pinned version

1. Pick a release from `desktop/dugite-native` and take the `.sha256` beside each
   asset.
2. Update `kGitRelease`, `kGitVersion` and every entry in `_builds`.
3. Pin the **full asset name** — it carries dugite's build SHA, so it cannot be
   rebuilt from the version string.
4. On macOS, confirm the new build still runs: `codesign -v` on `bin/git`, then a
   real `git clone` over HTTPS with the three environment variables set. An
   unsigned arm64 binary is killed on launch.

## Verifying a change here

The install path can be exercised end-to-end without touching the machine's own
Git: the probe honours `DEVELOPER_DIR` and `GridPaths` honours `GRID_HOME`, so
pointing both at empty directories makes the app believe there is no Git while
leaving the real one alone. `brew unlink git` (reversible with `brew link git`)
removes the last one on `PATH`.

What that run must show:

- `findExecutable('git')` finds `/usr/bin/git`, and the probe still answers
  `GitMissing` — promptly, and without a dialog appearing
- after installing, `GitReady(ours: true)`
- `git clone` over HTTPS succeeds resolving `git` **from `PATH`**, not by absolute
  path — that is what proves ours beat the stub

Note the probe compiles and runs outside Flutter (`dart compile exe`), which is
why `git_probe.dart` has no framework import. Setting a fake `DEVELOPER_DIR` for a
`dart run` breaks the Dart toolchain itself, since its build hooks need `xcrun`.
