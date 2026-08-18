# Grid — Style Guide

> A single reference for the whole design system the Grid app runs on, detailed
> enough that **another app could rebuild this exact look and feel**. Prose is in
> English; tokens/hex/code names are left as they appear in the codebase so they
> can be pasted straight in.
>
> Source of truth in the repo: [`lib/shared/theme/app_theme.dart`](../lib/shared/theme/app_theme.dart)
> (every token) and [`lib/shared/widgets/`](../lib/shared/widgets/) (components).
> This file is the explanation + lookup table; when the two disagree, **the code
> is authoritative**.

---

## 0. Philosophy — "Codex-like macOS desktop"

This is a **desktop app** (macOS/Linux/Windows) for **non-technical** users. The
whole style turns on one sentence: *calm, flat, clean, like a native macOS app (in
the Codex direction) — not a web page, and not a phone app blown up.*

The founding principles (keep them when porting to another app):

- **Nearly borderless.** Separate surfaces with a **soft shadow** and a **1px
  hairline**, not a heavy rule or a boxed frame.
- **Bright, airy "liquid glass" surfaces:** white / very light grey, lots of room
  to breathe.
- **Moderate contrast.** Avoid dense slabs, hard borders, smeared shadows.
- **Corners on the macOS scale** (button ~8, card ~12, menu ~6) — *not* the hard
  rounding of iOS/web.
- **Motion is for continuity, not decoration.** ~130ms, `easeOut`.
- **Copy is part of quality.** This is a product for ordinary people, not a dev
  tool — the words have to be human-readable (see §10).
- **Light & dark always travel together.** Every token has both values; never
  hardcode a colour.

Short original reference: [`.codex/notes/grid-codex-style.md`](../.codex/notes/grid-codex-style.md).

---

## 1. The theme system (the foundation under every token)

The app does **not** read brightness from the OS directly. There is **one global**
`AppTheme.brightness` (light/dark) that all colour tokens resolve against. A widget
syncs it from `Theme.of(context).brightness` (the brightness Material actually
resolved after `ThemeMode.system` is applied), so the tokens always match what the
framework rendered.

The mechanics to carry over verbatim when rebuilding:

- **Tokens are getters, not consts.** `AppPalette.windowBg` is a getter that
  switches on brightness → the call site never needs to know whether it's light or
  dark.
  ```dart
  static Color get windowBg =>
      AppTheme.pick(const Color(0xFFFFFFFF), const Color(0xFF0A0A0A));
  //  AppTheme.pick(light_value, dark_value)
  ```
- **`AppTheme.watch(context)`** must be called at the top of `build()` for every
  **`const`** widget that reads a token (sidebar, card, pill…). Because a `const`
  child doesn't rebuild when its parent does, without watching it gets stuck on the
  palette it first built with (a dark chip left on a light page). The mechanism:
  `InheritedNotifier` (`BrightnessScope`) marks dependents dirty *directly*, across
  every `const` boundary. The same `watch` also picks up the user's type-setting
  changes (`_FontScope`), so it is the one line a widget adds to follow the app's
  appearance.
- **`AppTheme.as(other, read)`** reads tokens as some *other* brightness would
  resolve them (used by the theme-preview swatches): swap → read → restore in a
  `finally`, with the swap done "muted" so it doesn't fire spurious rebuilds.

> The golden rule for another app: **don't scatter `Theme.of(context).brightness`
> everywhere with if/else.** One global + getter tokens + one `watch()` for const
> widgets. Change a number at the token, not at the call site.

---

## 2. The palette (`AppPalette`)

Light = **warm paper white + near-black ink**. Dark = **deep charcoal + off-white
ink**. It all lives on `AppPalette` — no hex is retyped anywhere.

| Token | Light | Dark | Used for |
|---|---|---|---|
| `windowBg` | `#FFFFFF` | `#0A0A0A` | Content / conversation area |
| `panelBg` | `#F9F9F8` | `#141414` | Sidebar column |
| `cardBg` | `#F3F3F2` | `#1E1E1E` | Input fills, quiet cards |
| `cardBgHover` | `#ECECEA` | `#252525` | Hover state of the above |
| `divider` | `#0F000000` (faint) | `#14FFFFFF` (faint) | 1px hairline separator |
| `accent` | `#2F5BEA` | `#2F5BEA` | **Primary action** (fill under white text) — fixed across both themes |
| `dangerFill` | `#B3261E` | `#C92E26` | Fill under a destructive **filled** button (Remove, Delete) |
| `accentOnSurface` | `#2F5BEA` | `#6E8BFF` | Accent as a **mark on a surface** (selected row icon) |
| `accentMuted` | `#3550C8` | `#4E6BF0` | Avatar fill (white text on it) |
| `teal` | `#0F766E` | `#2DD4BF` | "Owner" badge |
| `online` | `#15803D` | `#3FB950` | "Connected" dot (green) |
| `warn` | `#B45309` | `#FFB020` | Expiring soon / warning |
| `offline` | `#A3A29C` | `#6E6E6E` | Grey dot |
| `brandBolt` | `#C98A00` | `#E0A93B` | Grid ⚡ brand mark (live) |
| `textPrimary` | `#1A1A18` | `#F5F5F5` | Primary text |
| `textSecondary` | `#62615B` | `#A8A8A2` | Secondary text |
| `textFaint` | `#8E8D86` | `#6E6E68` | Faint text / captions / section labels |

**The important lesson** (don't "fix" it back): `accent` has to be separate from
`accentOnSurface` in dark. `accent` is the fill under white text in ~100 places
(white on it = 5.5:1). But `#2F5BEA` used as an **icon** on a dark row (compositing
to ~#2A2A2A) reaches only 2.6:1 < 3.0 (WCAG 1.4.11). So accent-as-a-mark uses the
lighter `#6E8BFF` (4.65:1). Don't merge the two tokens: lightening `accent` would
drop the white button text to ~3.1:1.

---

## 3. Surface & elevation

Four groups of tokens, each with one role — **don't mix them**.

### 3.1 `AppSurface` — chrome layer (sidebar rows, recessed wells)
A black overlay (on a light ground) ↔ white (on a dark ground) so hover/selected
read on either:

| Token | Light | Dark | Role |
|---|---|---|---|
| `selectedFill` | `#0D000000` | `#14FFFFFF` | The sidebar row you're **on** |
| `hoverFill` | `#07000000` | `#0DFFFFFF` | Row under the **pointer** (lighter than selected — hover must not read as selected) |
| `accentWash` | `#142F5BEA` | `#242F5BEA` | A whisper of accent washed under the primary action ("New chat"), not yet hardened into a button |
| `accentWashHover` | `#1F2F5BEA` | `#332F5BEA` | The stronger version, when that action is hovered |
| `wellFill` | `#12000000` | `#0FFFFFFF` | The translucent icon well inside a list row |
| `recess` | `#08000000` | `#0FFFFFFF` | A recessed well inside a panel (the list column) |
| `recessHover` | `#12000000` | `#1AFFFFFF` | The recessed well when hovered (the account pill) |
| `scrollThumb` | `#8C8C8C` | `#686868` | Scrollbar thumb at rest (opaque, per-brightness — 3.36:1 / 3.55:1) |
| `scrollThumbHover` | `#6E6E6E` | `#8A8A8A` | The thumb under the pointer / mid-drag |
| `shadow` | 2 layers (see code) | deeper | Drop shadow lifting a floating surface (the composer) |
| `composerShadow` | 2 layers, wide + low | deeper | The composer's own lift (clearly floats over the transcript) |

### 3.2 `AppGlass` — translucent chrome behind a backdrop blur (sidebar, top bar, pills, menus)
| Token | Light | Dark | Role |
|---|---|---|---|
| `sidebarFill` | `#F7F9F9F8` (near-opaque) | `#F01A1A1A` | The rail's surface |
| `surfaceFill` | `#FFFFFF` | `#202020` | Pill/menu (solid white; softness comes from rim + shadow) |
| `surfaceHoverFill` | `#F7F7F6` | `#272727` | Hover of the above |
| `hair` | `#14000000` | `#1FFFFFFF` | Rim hairline |
| `lift` | `#2E000000` | `#2EFFFFFF` | A more present rim for surfaces that must read as *lifted* (the composer) |
| `bubbleFill` | `#F3F3F1` | `#242424` | The user's message bubble |
| `rowFill` | `#F3F3F2` | `#202020` | A list row sitting directly on the page, at rest |
| `rowHoverFill` | `#EAEAE7` | `#272727` | The same row under the pointer |
| `shadow` / `cardShadow` | soft | deeper | Lift for a floating pill/menu |

### 3.3 `AppCard` — content-card recipe (applied via `GlassCard`)
- Surface: `base` (`#FFFFFF` / `#1E1E1E`); recessed tile: `inset` (`#F7F7F5` / `#181818`).
- Accent tints (used sparingly): `tint10` / `tint18` / `tint25`.
- **Corners:** `radius = 12` (card), `insetRadius = 8` (tile inside a card).
- Shadows: `shadow` (soft ambient) and `heroShadow` (focal card, stronger + an accent aura).

### 3.4 How to pick a group
```
Chrome (rail/topbar/pill/menu)          → AppSurface / AppGlass
Content card (grid/engine details)      → AppCard  (via GlassCard)
A quiet input                           → AppPalette.cardBg
```
Depth **always** comes from a *hairline rim + soft shadow*, never from a heavy border.

---

## 4. Typography (`AppFont` + text theme)

### 4.1 The two font stacks and the rule for picking one
> **Mono is for strings the user *copies*, not strings they *read*.**

| Stack | Value | Used for |
|---|---|---|
| `AppFont.sans` | `.AppleSystemUIFont` (fallback: SF Pro Text, Helvetica Neue, Arial) | All prose: headings, subtitles, names |
| `AppFont.mono` | `.AppleSystemUIFontMonospaced` (fallback: Menlo, Monaco, Courier New, monospace) | model id, endpoint, token, code — anything where `l/1/I` and `0/O` have to stay apart |

Both are getters, not consts: the user can put a family of their own in front from
Appearance, with the shipped default (`sansDefault` / `monoDefault`) still the
fallback.

Pitfall: the string `'SF Mono'` does **not** resolve (CoreText returns nil → it
silently falls through to Menlo). Only the internal name
`.AppleSystemUIFontMonospaced` reaches the real SF Mono. **Numbers** do NOT use mono
— use `AppFont.tabularFigures` (`FontFeature.tabularFigures()`) on the sans stack so
digits don't reflow as the value changes.

The weight ladder is three steps — reach for `medium` first:
- `regular` = `w400` — body copy, anything simply being read.
- `medium` = `w500` — the workhorse: control labels, sidebar items, row titles,
  table headers. (This is the weight that used to be semibold in 133 places.)
- `semibold` = `w600` — reserved for type that must out-rank the medium beside it:
  a screen or section heading, the selected row in a menu.

### 4.2 The text-theme ramp (light: primary `#1A1A18`, secondary `#62615B`)
Base: system font, `height: 1.34`, `w400`. Letter-spacing is **not** a flat 0 — it
comes from `AppFont.trackingFor(size)`, an Apple-derived tracking curve (`≥28pt:
-0.4`, `≥20pt: -0.25`, `≥17pt: -0.1`, `≥15pt: 0`, `≥13pt: +0.05`, `<13pt: +0.12`).
Headings keep `semibold`; type that merely names a control drops to `medium`.

| Style | Size | Weight | | Style | Size | Weight |
|---|---|---|---|---|---|---|
| displayLarge | 57 | 600 | | titleSmall | 14.5 | 500 |
| displayMedium | 45 | 600 | | bodyLarge | 16.5 | 400 |
| displaySmall | 36 | 600 | | bodyMedium | 15 | 400 |
| headlineLarge | 32 | 600 | | bodySmall | 13.5 | 400 (secondary) |
| headlineMedium | 29 | 600 | | labelLarge | 14.5 | 500 |
| headlineSmall | 25 | 600 | | labelMedium | 13 | 500 |
| titleLarge | 22 | 600 | | labelSmall | 12 | 500 |
| titleMedium | 17 | 600 | | | | |

Section titles use `headlineSmall`; subtitles use `bodyMedium` in `onSurfaceVariant`.

---

## 5. Control sizes (`AppControl`) — "one set of numbers for every button"

A macOS control is compact, slightly squarish, quiet: a **13pt medium** label in a
~32px capsule, gently rounded. **Change a number here, not at a call site.**

| Token | Value | Meaning |
|---|---|---|
| `height` | **32** | Standard control height |
| `heightSmall` | 28 | A compact control (inline action in a row / card header) |
| `heightField` | 36 | A search field at the head of a list — taller than a button because it's for *typing*, not *clicking* |
| `radius` | **8** | Button rounding (Apple: gently rounded, NOT stadium/pill) |
| `menuRadius` | **6** | Menu/popover rounding — tighter than a button |
| `menuMaxHeight` | 240 | The tallest a menu panel ever draws (upward menus size themselves by this) |
| `fontSize` | **13** | Control label |
| `fontWeight` | `AppFont.medium` (`w500`) | |
| `iconSize` | 16 | The glyph inside a button (sits on the cap height of a 13pt label) |
| `iconSizeChip` | 13 | The glyph on a chip (11pt label) |
| `padding` | `horizontal: 14` | Button side padding |
| `paddingSmall` | `horizontal: 10` | Compact button |
| `paddingSmallIcon` | `left: 12, right: 10` | Compact `.icon` button (extra leading pad buys back what a glyph lacks) |

The `*Scaled` variants (`heightScaled`, `heightFieldScaled`, `paddingScaled`,
`paddingSmallScaled`) grow the *box* by `AppFont.uiScale` for the user's UI size;
`fontSize` deliberately has no scaled twin — the label is a `Text`, so `MediaQuery`'s
text scaler already grows it (scaling both would apply the setting twice).

**The most important rule:** every `FilledButton/OutlinedButton/TextButton` must set
`tapTargetSize: MaterialTapTargetSize.shrinkWrap`. Material's default pads out to a
48px touch box → a 32px button floats loose in a 48px box and breaks every row it
sits in. (Already set in `filledButtonTheme/outlinedButtonTheme/textButtonTheme` —
but if you `styleFrom` yourself, remember it.)

Corners on the macOS scale (don't round harder): **button 8 · card 12 · inset 8 ·
menu 6 · dialog 12 (=card) · snackbar 13 · toast 15 · toolbar pill 11**.

---

## 6. Motion (`AppMotion`)

| Token | Value | Used for |
|---|---|---|
| `hover` | **130ms** | A surface reacting to the pointer (a row's hover fill, a chip warming up) |
| `swap` | 160ms | Content replaced in place (a list swapping to another grid's models) |
| `fold` | 220ms | A panel folding/unfolding (the sidebar collapsing to its glyphs) — longer because the whole layout shifts |
| `curve` | `Curves.easeOut` | The app's curve — fast to start, settling at the end |

Motion is for **continuity, not decoration**: it says "the thing you're looking at
is the same thing it was a moment ago." Anything long enough to *notice as an
animation* is too long for a hover. Always honour **Reduce Motion**
(`MediaQuery.disableAnimations`) → drop the animation, show the static state.

---

## 7. Spacing

There is no separate spacing token — the app uses a consistent, repeated scale via
`SizedBox`/`EdgeInsets`:

| Context | Value |
|---|---|
| A section's padding (`SectionScaffold`) | **24** on all sides |
| Title → divider → body | 16 · divider 1 · 16 |
| Title → subtitle | 4 |
| Generous gap inside a card / between groups | 12–18 |
| Ordinary gap (label → control, icon → text) | 8 |
| Tight gap (value → sub-label) | 2–6 |
| Padding inside a card row (MetaRow / AddressRow) | `horizontal: 14`, `vertical: 10–11` |
| Divider inside a card | `Divider(height: 1, indent: 14, endIndent: 14)` |

Convention: comment *above* the code to explain *why*; **no** trailing comment.
Line ≤ 80.

---

## 8. The shared component library (`lib/shared/widgets/`)

Before building a new widget, **reuse** what's there. The catalogue:

### 8.1 Buttons
- **`FilledButton`** = primary action: a solid accent capsule, white text.
- **`OutlinedButton`** = secondary action: a hairline rim only, no fill (Apple's
  "bordered" button).
- **`TextButton`** = tertiary action: text only (the quiet way out of a dialog).
- All three are pre-themed (height 32, radius 8, 13pt `medium`, shrinkWrap). Only
  `styleFrom` when you need to deviate. A destructive filled button uses
  `dangerButtonStyle()` (fill `AppPalette.dangerFill`, white text).

### 8.2 `PillChoice` — a segmented pill for the toolbar
Height **34**, radius **11**, 13.5pt `AppFont.medium`, animates over 140ms. Selected
= `accent` fill + white text + `AppGlass.cardShadow`; unselected = `AppGlass.surfaceFill`
+ `textSecondary`. **A row of buttons/pills/search has to read as ONE bar:** keep the
same 34px height across the whole bar. Don't roll your own pill — reuse `PillChoice`.

### 8.3 `GlassCard` — a content card (3 styles)
```dart
GlassCardStyle.card   // standard card: white, hairline rim, soft lift
GlassCardStyle.hero   // focal card: accent wash + rim + heroShadow, leads the screen
GlassCardStyle.inset  // a recessed well inside a card (list tile, log panel) — no wash/glow
```
The "glass" detail: a diagonal wash gradient fading out, an accent aura anchored to
the top-right corner, a specular hairline along the top edge. Only **one** focal
card per screen wears the accent.

### 8.4 `SectionScaffold` — the frame for each nav screen
`Padding(24)` → `Text(title, headlineSmall)` → subtitle (bodyMedium,
onSurfaceVariant) → `Divider(1)` → body in `Expanded`. Every section view shares it
so margins and titles stay consistent. (`ComingSoon` in the same file is the
placeholder for unimplemented sections.)

### 8.5 The detail pane — `DetailSection` / `MetaRow` / `AddressRow` / `BadgePill`
- `DetailSection(title, children, trailing?)`: heading **UPPERCASE 11pt,
  letterSpacing 0.6, `AppFont.medium`, `textFaint`** + a `GlassCard` holding rows
  separated by an indent-14 divider.
- `MetaRow(label → value)`: label `textSecondary` on the left, value `textPrimary`
  right-aligned.
- `AddressRow(label, value)`: value in **mono** (a URL/ID to copy) + a
  `CopyIconButton` in the corner.
- `BadgePill(label, color)`: a radius-6 pill, fill `color@16%`, border `color@45%`,
  label `color` w600. Roles use the right token: Owner = `teal`, Public = `accent`.

### 8.6 `StatusDot` — a status dot
A 9px circle + a soft glow (`color@50%`, blur 5). `pulsing: true` → a breathing halo
(1600ms) for a "live" state. Colours come from the palette: `online` / `offline` /
`warn`. Honours Reduce Motion.

### 8.7 `EmptyState` — the empty state
`icon + title + message? + action?`. **Two flavours:** *nothing here yet* → carries
an `action` to create the first one; *nothing matches the filter* →
`EmptyState.noMatches` (no action; the fix is changing the query). `compact` for an
empty state inside a card / narrow column.

### 8.8 `LabeledField` / `FieldLabel` — forms
The label **sits still above** the control (macOS doesn't float a label into the box
like Material). The field: a soft borderless capsule, fill `cardBg`, radius 12, with
a 1.5px accent hairline appearing only on focus. `labeledFieldDecoration(hint)`
reuses the same surface for a hand-built `TextField` (multiline).

### 8.9 `Toast` — notifications (with hierarchy)
A single host (`ToastScope`); call `ToastScope.show(context, spec)` from anywhere —
it **survives an `await` and a `Navigator.pop`** (there is exactly one host, tracked
by a static, so no live context is needed). A top-centre macOS-style banner, a glass
surface (radius 15), a severity chip, an action, flick-up to dismiss. Severity sets
icon/colour/duration:

| Severity | Colour | Icon | Duration |
|---|---|---|---|
| `info` | `accent` | info_outline_rounded | 4s |
| `success` | `online` | check_circle_outline_rounded | 4s |
| `warning` | `warn` | warning_amber_rounded | 5s |
| `error` | red `#B3261E`/`#F2544B` | error_outline_rounded | 6s |

Helpers: `ToastScope.showResult(context, error:, success:)` — error≠null → error,
otherwise success. `copyToClipboard(context, text, {message})` copies + shows a
"Copied" toast (1s).

### 8.10 Code — `CodeBlock` / `GuideLabel` / `CopyIconButton` / `CopyButton`
`CodeBlock`: `AppGlass.surfaceFill` background, `AppGlass.cardShadow` (fill + shadow,
not a border), radius 8 (`insetRadius`), selectable **mono** text + a copy button in
the corner. `CopyIconButton` (secondary, corner) vs `CopyButton` (a tonal-accent
pill, when copying is the primary action).

### 8.11 `SidebarItem` — one rail row
The sidebar's single row recipe (nav, "New chat", saved conversations) → the same
padding/hover for all. Row height 36, radius 8. The icon takes the accent
(`accentOnSurface`) when the row stands out (`selected` or `emphasized`); `trailing`
reveals on hover (a delete button); `badge` is an always-visible mark (an unread
dot). Calls `AppTheme.watch` because the rail is `const`. `SidebarSectionLabel` is
the quiet, optionally-foldable group label above a set of rows.

### 8.12 Around the composer — decide above, status below, news in the transcript
Three places, and which one a thing goes in is decided by what it is, not by who
wrote it:
- **Waiting on the user** → a `ComposerNoticeBar` *above* the composer (a plan to
  approve, a turn that ran out of steps, a skill to save, an agent the grid swapped).
  Bordered, one line, its actions on the right. This is the only kind that gets to
  interrupt.
- **Still running** → a `StatusNote` in the `ComposerStatusLine` *under* the
  composer: no card, no shadow, no accent — faint text at 12px and quiet actions, at
  most two rows plus "N more". A goal being worked toward, a repeating prompt, a
  server the agent left running.
- **Already happened** → a `TranscriptEventRow` **in the conversation**, at the turn
  it happened on (`endedAfter` / `through` anchors it). Goal met, loop stopped,
  context compacted.

The rule exists because the app had it wrong: goal, loop and running servers each
drew their own bordered card above the composer and stayed there until dismissed —
up to four boxes between the transcript and the box you were typing in, none of them
asking for anything. Claude Code and Codex both keep one quiet status line and put
the news in the scroll; so does this.

### 8.13 Feature-scoped tokens (the `OverlordTokens` pattern)
When a feature has its own "look" (e.g. the telemetry dashboard: mono, teal "live",
colour by load), collect those tokens in **one file scoped to the feature** — but
**surfaces still come from `AppPalette`** so the feature sits flush with everything
else. Don't scatter colour constants through the widgets.

---

## 9. Layout & navigation

- **The sidebar (the daily rail) is for *doing*, not *configuring*.** Everyday work
  (Chat/Playground…) lives on the rail.
- **Setup/plumbing screens (Grids / This computer / Telegram / How to use) live
  behind **Settings** (`SettingsPane`), full-screen:** a nav list on the left, the
  screen on the right, "Back to app" in the header. On a narrow window (<1000px) the
  nav collapses to icon + tooltip.
- **A seamless top bar:** 46px tall (`AppTopBar.height`), **no fill/border/blur** —
  just a row of pills floating over the pane plus the window drag handle
  (`DragToMoveArea`). An empty pill unmounts; no bare capsule left behind. A hairline
  appears under the bar only when a named conversation or project is open.
- **One bright row at a time:** the highlight means "this is the screen you're on."
  A chat row may still be active in state but **must not look selected** while
  another section is open.
- Desktop windows resize → **nothing may overflow**: `Expanded`/`Flexible`/`Wrap`
  inside Row/Column (never mix `Flexible` and `Expanded` in the same one);
  `LayoutBuilder`/`MediaQuery` for responsive decisions. A long list is always a
  `ListView.builder`/`SliverList`, never a mapped `Column`.

---

## 10. Copy & UX (this is a product, not a dev tool)

- **Everyday language.** Avoid jargon (node, GGUF, llama.cpp, provider/consumer,
  scope, base URL) in the main copy — or explain it in place.
- **Every screen state handles empty / loading / error**, and each one is
  **actionable** (a button, or a clear "what to do next" line).
- **After every action, respond in human terms:** success / failure / progress +
  the next step.
- **Honest labels.** Never show "Connected" when it isn't, or "Start engine" when it
  doesn't start. **One word per concept** across the app (don't mix
  engine/provider/Sharing).
- Technical errors (CLI stderr) → mapped to a friendly sentence in the main UI; keep
  the raw text for the Debug/command log.
- **There are no UI tests** to catch copy → self-review copy on every UI diff.

---

## 11. Accessibility

- **Contrast** ≥ 4.5:1 for body text (≥ 3:1 for large/bold ≥18pt) — one more reason
  to use themed colours, not hardcoded ones. (See the `accentOnSurface` case in §2.)
- **Dynamic text scaling:** stay usable when the OS grows the type — don't hardcode a
  height/box that clips scaled text.
- **`Semantics`** for non-obvious controls; **`tooltip`** for icon-only buttons.
- Honour **Reduce Motion** (StatusDot, Toast, every animation).
- No ALL-CAPS for long-form text (only micro-labels like the UPPERCASE 11pt section
  heading).

---

## 12. Architecture & state (the base the style attaches to)

- **Feature-first:** `lib/features/<feature>/{logic,presentation}`. Cross-cutting
  lives in `lib/infrastructure`, `lib/shared`, `lib/core`.
- **Dependency direction:** presentation → logic → infrastructure. Never the
  reverse. Presentation **never** touches the CLI/filesystem directly — go through a
  provider/controller.
- **State = Riverpod.** Read reactively with `ref.watch`; act with
  `ref.read(xController.notifier).doThing()`. Prefer narrow providers/selectors over
  watching a whole object.
- **No "boolean soup":** model controller state with a `sealed class` + an exhaustive
  `switch` (e.g. `ProviderRunState`, `ModelPullState`).
- **No side effects in `build()`** or in a notifier's updater — move them to
  `addPostFrameCallback`. Release resources in `ref.onDispose`/`dispose()`.

---

## 13. Definition of done (self-review the diff before saying "done")

- `flutter analyze lib test` → **0 issues**. `dart format` 80-col.
- **Reuse before writing:** call an existing helper/const (`AppPalette`,
  `PillChoice`, `GlassCard`, `DetailSection`, `EmptyState`…) instead of retyping a
  literal / re-implementing a body. Repeated 2+ times → extract.
- Small, single-purpose widgets; split a big `build()` into **private**
  `_SubWidget` classes (not methods returning a Widget); files ~200 lines.
- **Themed colours** (no hardcoding), **exhaustive sealed state**, **honest,
  everyday copy**.
- No dead/commented-out code, no always-false branch — delete it, don't bury it
  behind a comment.
- Flag real risks **loudly** (`TODO(BE)`/an explicit note), never hidden.
- Test **logic only** (pure functions, controllers, services) — **do not** write
  widget/UI tests.

---

### A portable checklist for "wearing" this style on another app
1. Stand up `AppTheme` (a global brightness + `pick/watch/as`) and `BrightnessScope`.
2. Copy all four token groups verbatim: `AppPalette`, `AppSurface`, `AppGlass`, `AppCard`.
3. Copy `AppControl`, `AppMotion`, `AppFont`; build `ThemeData` from **one** function for both brightnesses.
4. Set buttons to 32/8/13pt-`medium` + `shrinkWrap`; label-above inputs with a 1.5px accent focus ring.
5. Bring over the shared components: `GlassCard`, `PillChoice`, `SectionScaffold`, `DetailSection`, `StatusDot`, `EmptyState`, `LabeledField`, `Toast`.
6. Layout: a rail-for-doing + full-screen-Settings-for-configuring, a seamless top bar, one-bright-row.
7. Review copy + accessibility + DoD on every diff.
