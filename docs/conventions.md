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
- **Never name a place you haven't checked** — "Settings ▸ Agents" was wrong; Agents is
  in the sidebar. Read `shell_state.dart` first.
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
  catch anything; `flutter analyze` + the running app is the check. The ones left in
  `test/` are legacy: update or delete them with the widget, never add more.
- **Do test the logic**, with every logic change: pure functions, controllers via
  `ProviderContainer(overrides: [...])`, services, stores.
- Arrange-Act-Assert; **fakes over mocks** (`FakeGridCliService`); **offline &
  deterministic** — never the network, never the real `~/.grid` (point stores at a temp
  dir). Tests live in `test/<area>/` mirroring features.
- A test name states the **behaviour and why it matters**, not the method it calls.
- Never change production code just to make a test pass; if a test finds a bug, flag it.

## 9. Definition of done

- `flutter analyze lib test` → **0 issues**; relevant `flutter test test/<area>` green.
  (Two failures pre-date any change: `provider_run_controller_test`, `sidebar_item_test`
  — report, don't chase.)
- Diff self-reviewed against this doc: no DRY violations, no dead code, small widgets,
  sealed-state exhaustiveness, themed colours, honest copy, tests updated.
- **Real risks flagged loudly** (`TODO(BE)`), never hidden behind a calm comment.

## 10. Tooling & git

- Flutter SDK isn't on the default `PATH` here:
  `export PATH="$HOME/WorkPlace/Flutter/flutter/bin:$PATH"`.
- `dart format` (80-col) + `dart fix`; lints from `flutter_lints`.
- Commits: imperative summary. An AI agent adds its own `Co-Authored-By:` trailer —
  each tool's root pointer file says which.
- **Branch off `main`, never commit straight to it.** Keep the diff scoped.
- **Tracked docs:** this file, `docs/style-guide-grid-app.md`, `CLAUDE.md`,
  `AGENTS.md`, `README.md` — everything §§1–11 tells you to read before working. The
  rest of `docs/` is local-only working notes and stays gitignored — if a note becomes
  a rule, move it here rather than leaving it on one machine.

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
