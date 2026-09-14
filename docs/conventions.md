# Grid app — code quality & conventions

The single source of truth for how code is written in this repo. Humans and AI
agents read this same file: `CLAUDE.md` and `AGENTS.md` at the root are thin
pointers to it, and carry only what is genuinely tool-specific.

Baseline is the official Flutter/Dart AI rules (`flutter/flutter →
docs/rules/rules.md`); §§1–11 win on conflict, and §12 lists the deviations that
are **deliberate** — don't "fix" them back.

## 0. What this is

- **Grid** — a Flutter **desktop** app (macOS/Linux/Windows) for peer-to-peer AI:
  people run local models (engines) and share them across a private "grid".
- Flutter/Dart `^3.9.2`, **Riverpod**, drives the `grid` CLI.
- Built for **non-technical users** — UX and copy are part of code quality.
- Held to a **leader/senior bar**, not "it works": implement to §§1–11, then
  self-review the diff against §9 before saying done.

## 1. Architecture

- **Feature-first:** `lib/features/<feature>/{logic,presentation}`. Cross-cutting:
  `lib/infrastructure/{cli,state,api}`, `lib/shared/{layouts,widgets,theme}`, `lib/core`.
- `logic/` = controllers, providers, pure functions, models. `presentation/` = widgets.
- **Dependency direction:** presentation → logic → infrastructure. Never the reverse,
  and never feature → another feature's internals: what two features share moves to
  `shared/`.
- Presentation never touches the CLI / filesystem / `~/.grid` — go through a provider
  or controller. The CLI owns on-disk state; the app reads it via stores/services.

## 2. State — Riverpod

- Expose state through providers, one source of truth per concern; prefer narrow
  providers/selectors over watching a big object for one field.
- `ref.watch` to read reactively; `ref.read(x.notifier).doThing()` for actions.
- Controller state = **`sealed class` + exhaustive `switch`** (`ProviderRunState`,
  `ModelPullState`). **No boolean soup.**
- **No side effects in `build()`** or in notifier updaters (they run twice under
  StrictMode) — mutate outside, e.g. `addPostFrameCallback` (see `ProviderView`).
- Release processes/controllers in `ref.onDispose` / `dispose()`.
- **A value class held as provider state carries `operator ==`/`hashCode`.** Riverpod
  decides whether to notify by comparing the old state with the new, so a state rebuilt
  from disk or the wire — a parse, a poll, a re-read — notifies on *identity* without
  one, and an unchanged file reads as a change. That is not a small waste: it is what a
  watcher does next. `NetworkCredential`/`CredentialsFile` had none, and every
  `sessionProvider` invalidation therefore re-fetched the grid's models, its member
  usage and `GET /grid/overview`, and made `servingEnginesProvider` re-list
  `~/.grid/run/engines` and spawn a `kill -0` per record on the UI isolate — for a grid
  that had not moved (measured: 6 downstream builds where 1 was owed;
  `test/network/credential_identity_test.dart`). `GridOverview` carries its own for the
  same reason. Services and controllers are the exception — identity is what they *are*.

## 3. Dart style

- **Effective Dart**, line length ≤ 80 (`dart format`).
- **Strong typing** — no `dynamic`; sealed types + pattern matching over type checks.
  Avoid `!` unless the value is guaranteed non-null.
- **Early returns**, shallow nesting, short single-purpose functions (~<20 lines).
- **Immutability:** `const` constructors, `final` fields, `List.unmodifiable(...)` for
  lists a controller exposes. **Records** instead of throwaway classes for multi-returns.
- **Arrow syntax** for one-liners; exhaustive `switch`, no `break`.
- **Comment above the code, never trailing** — explain *why*, not *what*.
- **Pure logic** (parsing, deriving, planning) lives in side-effect-free functions and
  is unit-tested: `buildSetupPlan`, `deriveAdvertiseName`, `codexExecArgs`, the parsers.
- **DRY:** reuse existing helpers/consts (`AppPalette`, `deriveAdvertiseName`,
  `networkConn`, `expiryLabel`) instead of re-typing a literal or re-implementing a
  body. Repeated 2+ times → extract.
- **No dead or commented-out code, no always-false branches** — delete it.

## 4. Widgets / UI

- **Small, composed widgets**, ~200 lines/file: split a big `build()` into private
  `_SubWidget` **classes**, not helper methods returning a `Widget`.
- `ConsumerWidget`/`ConsumerStatefulWidget` when reading providers, `StatelessWidget`
  otherwise. No business logic in widgets — delegate to controllers.
- **`const` wherever valid.** No network calls or heavy compute in `build()` — offload
  to `compute()`. Long lists lazily (`ListView.builder`), never a mapped `Column`.
- **Overflow-safe:** `Expanded`/`Flexible`/`Wrap` in rows & columns (never mix them in
  the same one); desktop windows resize — nothing may overflow.
- **Theme, not hardcode:** `Theme.of(context)` + `AppPalette`; tokens and component
  themes live in `app_theme.dart`; interactive states via `WidgetStateProperty`.
- **Reuse shared widgets first:** `SectionScaffold`, `DetailSection`, `ChoiceCard`,
  `SoftActionButton`, `AddressRow`, `MetaRow`, `LogView`, `StatusDot`, `EngineBlock`.
- **Doc comment (`///`) on every public class/API:** one-sentence summary, blank line,
  then detail — what it is *and why*, before any annotation.
- Icon-only buttons need a `tooltip`; respect tap-target sizes.
- Full visual spec — spacing, radii, toolbar metrics, one-bright-row rule — lives in
  `docs/style-guide-grid-app.md`. Read it before any UI task.

## 5. User-facing copy (a product, not a dev tool)

- Plain language; no jargon (node, GGUF, llama.cpp, scopes, base URL) unless explained.
- Every state — **empty / loading / error** — is **actionable**: a button or a clear
  next step. After an action, show success/failure/progress in human terms.
- **Honest labels.** Never "Connected" when it isn't. Never promise a fallback works
  ("Hermes works here" shipped while Hermes was failing on that grid) — offer it to try.
- **Never name a place you haven't checked** — "Settings ▸ Agents" was wrong when Agents
  was a sidebar row, and it moved into Settings ▸ Customize on 2026-08-11, so the copy
  that was right is now wrong too. Read `shell_state.dart` first, every time.
- A line that reports a failure and reassures at once ("Couldn't check for updates:
  You're up to date!") is a **bug**, not wording — fix the state behind it.
- One word per concept across the app; **two screens asking the same question share the
  widget and the words** (`ChoiceCard`, `api_engine_choices.dart`) — copies drift.
- Self-review copy on every UI diff: there are no UI tests to catch it (§8).

## 6. Errors & async

- `async`/`await`, typed `Future`/`Stream`, never raw callbacks.
- Catch at the **controller boundary**; map to a sealed `...Failed` state with a
  user-friendly message (see `_friendlyLoginError`, `friendlyAgentServerError`).
- **Humanizing is never the only record:** log the raw failure (`appLogProvider`) *as
  well* — a log that repeats the sentence the user just read diagnoses nothing. Same
  trap in reverse: stderr collected and never read is dead code that costs a session.
- **Timeouts** on external/CLI waits, and always a cancel/stop path.

## 7. CLI integration

- All `grid` calls go through `GridCliService` (+ its logging wrappers) — never ad-hoc
  `Process.run` in a feature. Stream long operations; cap retained log lines.
- **Flags are per-subcommand** (`codex exec` takes `--sandbox`/`-C`, `codex exec resume`
  takes neither and rejects the whole invocation). Check `<cmd> --help` before wiring
  one, and build argv in a **pure, tested** function — a wrong flag fails exactly like
  a model that wouldn't answer.
- **Diagnosing ≠ verifying:** probing the real CLI/endpoint for evidence of a *reported*
  failure is right; curling to check your own change works is not.

## 8. Testing — logic only, **no UI tests**

- **Never write widget/UI tests** — no `testWidgets`, no pumping, no asserting on
  layout or rendered text. The UI is redesigned weekly, so they rot faster than they
  catch anything; `flutter analyze` + the running app is the check. There are none
  left to copy from either: the last 21 files went on 2026-08-11, and the pure
  functions a few of them also covered moved to files named after what they test.
  `grep -rl 'testWidgets\|pumpWidget\|WidgetTester' test` must stay empty.
- **Only the grid, the agents, and wire formats are tested.** `test/` holds exactly
  these areas and no others: `agent`, `agents`, `network`, `chat`, `code`,
  `playground`, `connectors`, `skills`, `scheduled`, `mcp`, `models`, `node_setup`,
  `panel`, `vectors`, `provider`, `provider_node`, `auto_router`, `messaging`,
  `pairing`.
  Everything else went on
  2026-08-11 (~700 tests: review, projects, onboarding, messaging, terminal, prompts,
  appearance, layouts, logging, core, and the CLI/credentials/store/wire-parse
  plumbing under `cli`, `auth`, `state`, `api`, `infrastructure`). Don't add a folder
  back — if a change outside these areas needs proving, prove it by running the app.
  **The one thing that earns a new folder is a byte format we have to agree on with
  something outside this repo**, which is why `panel` exists (2026-08-13, the USB
  framing shared with whatever device is on the other end of the cable — see
  `docs/panel-protocol.md`) — and why `messaging` came back (2026-09-11): the
  Telegram Bot API Grid now speaks itself — the updates it reads, the HTML
  subset and 4096-character limit it writes — is a format agreed with Telegram,
  and the gate deciding who may make this computer act is not something to
  prove by hand. It tests that protocol and that gate, never the Messages
  screen. **`pairing` joined them on 2026-09-14** on the same grounds: the
  encrypted channel to the phone app is a byte format agreed with a binary that
  ships separately from this one — a handshake transcript, an HKDF schedule and
  a frame layout that two independently released builds must derive identically
  or not talk at all. It is also the worst possible thing to debug by running the
  app: a one-byte disagreement in the transcript surfaces as a decrypt failure
  on frame one, with nothing on either side naming the field that differs. It
  tests the codec and the key schedule, never a pairing screen. The reason §8
  cuts tests is that UI
  rots faster than tests catch it; a codec is the opposite — it never rots, it is
  pure, and it fails as a desync three layers away from the mistake, which running
  the app diagnoses very badly. Adding an area is still a decision to argue for
  here, not a habit. `vectors/` is not a fifth area but the *evidence* `panel/`
  asserts against: `panel_frame.txt`, generated from the protocol document by
  `scripts/gen_panel_vectors.py` — a third implementation — and read by both the
  Dart codec and the firmware's host-compiled test. A copy per side would let one
  drift and still pass, which is the one thing a shared vector file prevents.
  `pairing` earns its keep there the same way: `e2ee_handshake.txt` comes from
  `scripts/gen_e2ee_vectors.py`, and that script's `--selftest` reproduces a
  *different project's* published known-answer vector before it will write the
  file — so the evidence is that two unrelated implementations agree, not that
  this one agrees with itself.
  **TODO(BE): that cut is not free**, and it took real guards with it —
  `GridCliService`'s argv and logging, `credentials.toml` parsing, `GridHomeStore`,
  and `GridOverview.fromJson` are now checked by nobody. Those are exactly the
  places this app has broken silently before, so a change to one of them deserves
  the running app and a careful read, not confidence.
- **Do test the logic** in those areas, with every logic change: pure functions,
  controllers via `ProviderContainer(overrides: [...])`, services, stores.
- Arrange-Act-Assert; **fakes over mocks** (`FakeGridCliService`); **offline &
  deterministic** — never the network, never the real `~/.grid` (point stores at a temp
  dir). Tests live in `test/<area>/` mirroring features.
- A test name states the **behaviour and why it matters**, not the method it calls.
- Never change production code just to make a test pass; if a test finds a bug, flag it.

## 9. Definition of done

- `flutter analyze lib test` → **0 issues**; relevant `flutter test test/<area>` green.
  Re-measured on `staging` on **2026-09-09**: **2952 tests across 236 files**, and a
  test failure you see is *yours* — there is no standing "known failure" list to hide
  behind. (There was one, twice over: it named
  `provider_run_controller_test` and `sidebar_item_test`, then 9 analyzer issues in
  `features/models/` and 3 overflow failures in `connectors_view_layout_test`. Every one
  of them outlived the problem it described. If you add a note like this, date it and
  re-measure before trusting it.)
  ✅ **`analyze` clears its bar as of 2026-09-09: 0 issues, on Flutter 3.47.2.** It had
  carried 3 since 2026-08-18 — two `unawaited_return_in_try_block` warnings and a
  `prefer_final_fields` info — and the note here said they were debt to clear rather than
  an allowance to spend. They are cleared. The two warnings were never only a lint: in
  both, the `finally` closed a callback socket / deleted a staging folder while the future
  the `try` had just returned was still running against it, so `return await` fixed a race
  and satisfied the analyzer as a side effect.
  **State the Flutter version with the count, always.** Those two warnings existed only on
  the newer analyzer, which is why `docs/architecture.md` counted **1** on the same tree
  the same day that this counted 3. CI still pins 3.44.4 (§10), so a count taken there and
  a count taken locally can disagree while both are right — the version is what makes the
  pair agree.
  ⚠️ **Two tests are flaky under a loaded machine**, both the same shape and both new
  with the off-isolate chat write: `chat/chat_store_scale_test.dart` and
  `chat/chat_sessions_controller_test.dart` fail their **tearDown** with
  `FileSystemException: Deletion failed … Directory not empty` — the temp dir is deleted
  while a write that now runs off the isolate is still landing in it. Each file passes on
  its own, twice over. Re-run the file before believing a failure there; the fix belongs
  in the teardown, not in a retry.
  **A third joined them on 2026-08-25: `chat/chat_sessions_reload_test.dart`.** Same rule,
  one difference worth knowing — it failed a *different test each time* across three runs
  ("a goal that had already ended…" twice, "the headers are dropped once…" once), and
  passed alone every time. A file whose failure moves is a file racing something, not a
  broken assertion, so don't go reading the test it named.
- **Run the whole suite as `flutter test --concurrency=12`** — 2952 tests in 236 files on
  a 10-core Mac took **35–46s** (2026-09-09); it was 26s idle and 61s under load for 2228
  tests in 190 files on 08-18, and 20s for 1599 in 156 files on 08-11. Wall time
  here says as much about what else is running as about the suite. Most of it is still
  *starting one suite per file*, not running tests: a file
  costs ~110ms to open and most of them finish their own tests in under 100ms. So if the
  run ever feels slow again, the lever is fewer files, not fewer assertions — one
  more `test/<area>/one_function_test.dart` costs more than the twenty tests inside
  it. Re-measure before quoting these.
- Diff self-reviewed against this doc: no DRY violations, no dead code, small widgets,
  sealed-state exhaustiveness, themed colours, honest copy, tests updated.
- **Real risks flagged loudly** (`TODO(BE)`), never hidden behind a calm comment.

## 10. Tooling & git

- **The SDK floor is real and `pubspec.yaml` is the only place that states it**
  (currently Dart `^3.10.0`). Check with `dart --version` before blaming your code: a
  too-old SDK fails at `pub get` with a version-solving error that never mentions
  Flutter, and `flutter upgrade` is usually the whole fix.
  **The ceiling is now real too: CI pins `flutter-version: 3.44.4`** (`.github/workflows/release.yml`,
  since `58687e7f` on 2026-08-18) and that pin is load-bearing, not tidiness. `channel: stable`
  with no version shipped DMGs built on an engine nobody here had ever launched — Flutter 3.47.0
  against the 3.44.4 developed on — and the symptom was the UI tearing itself apart on users'
  machines while the same commit rendered perfectly when built locally. If you upgrade your own
  Flutter, you are no longer building what ships; verify a release build before assuming a
  rendering bug is in this repo.
  This line used to hardcode one machine's SDK path. It was wrong on the next machine
  someone worked from, which meant `which flutter` quietly kept resolving to an
  ancient copy while the doc insisted otherwise — so locate yours, don't copy a path.
- `dart format` (80-col) + `dart fix`; lints from `flutter_lints`.
- Commits: imperative summary. An AI agent adds its own `Co-Authored-By:` trailer —
  each tool's root pointer file says which.
- **Branch off `main`, never commit straight to it.** Keep the diff scoped.
- **Tracked docs:** this file, `docs/style-guide-grid-app.md`, `CLAUDE.md`,
  `AGENTS.md`, `README.md` — everything §§1–11 tells you to read before working —
  and the two agent-lane maps, `docs/claude-rendering.md` and
  `docs/codex-rendering.md`: read one before changing how that agent's stream is
  drawn, and change it with the code it maps. The rest of `docs/` is local-only
  working notes and stays gitignored — if a note becomes a rule, move it here rather
  than leaving it on one machine.

## 11. Accessibility

- **Contrast** ≥ 4.5:1 (≥ 3:1 for ≥18pt bold) — one more reason to use themed colours.
- Stay usable when the OS font size grows; don't hardcode heights that clip scaled text.
- `Semantics` labels for non-obvious controls; no all-caps for long-form text.

## 12. Deliberate deviations from the upstream Flutter rules

- **State:** Riverpod, not built-in-only `ValueNotifier`/`ChangeNotifier`.
- **Persistence:** hand-read the CLI's TOML/JSON under `~/.grid` (`GridHomeStore`) — no
  `json_serializable` / `build_runner`.
- **Navigation:** a custom desktop shell (`shell_state` / `home_shell`), not `go_router`.
- **Logging:** the app's own stack (`appLogProvider`, `CommandLogNotifier`,
  `~/.grid/logs`), not `dart:developer` — and **never `print`**.
- **Testing:** logic only, no widget/UI tests (§8), where upstream asks for them.
