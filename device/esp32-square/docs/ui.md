# Grid Panel — drawing rules

Rules for `main/ui/`, each written down because something went wrong first. Geometry constants and
the two scaling rules live in the header of `ui_screens.c`; this file is for the things that are not
about layout values but about how LVGL behaves on this board.

---

## A wrapping label must never take its width from a percentage

**The rule.** A label with `LV_LABEL_LONG_MODE_WRAP` gets an **absolute** width, computed from
`SCR_W` / `ROW_W`. Never `lv_pct(100)` — most of all inside a scrollable box.

**The bug it comes from.** The recap label was `lv_pct(100)` wide, wrapping, inside a scroll box set
to `LV_SCROLLBAR_MODE_AUTO`. That is a loop:

```
scrollbar appears → content width shrinks → the label re-wraps → its height changes
    → whether a scrollbar is needed changes → …
```

Every pass re-measures every glyph of the recap in Geist. On the glass it read as the tile
flickering and the swipe stuttering — the reporter's words were *"like it redraws the UI dozens of
times"*, which is exactly what it was doing.

**How it was found**, and the order matters because most of the work was elimination:

- The display driver, draw-buffer size and LVGL memory pool are **byte-identical to the reference
  firmware** that runs smoothly on this same board — so none of them was the difference.
- The scroll handler runs only on `LV_EVENT_SCROLL_END` and returns early when the column has not
  changed. The one timer (`busy_tick`, 300 ms) returns early unless the *active* tile is busy.
- The link was **not** flapping: `hello` arrived every 15 s to the second, with no reconnects, so
  no message traffic was arriving during a swipe. This killed the first hypothesis, which was that
  the app was re-sending `projects` and the firmware was rebuilding every tile
  (`ui_projects_replace` does call `lv_obj_clean`, so it was a fair guess — just not what happened).
- The keepalive interval **not drifting** also proves the loop is scroll-triggered rather than
  free-running: an oscillation that spun on its own would have starved the timer.

**Why only one label had it.** `name_lbl`, `meta_lbl` and `step_lbl` are all `LONG_MODE_DOTS` —
single line, no re-wrap, no loop. `say_lbl` wraps but has a fixed height and sits in a box with no
scrollbar. The recap label was the only place all three conditions met: wrapping, percentage width,
and an AUTO scrollbar above it.

**The general form**, worth keeping in mind beyond this one label: *a percentage size that feeds a
decision which changes that percentage is a loop.* An AUTO scrollbar is the common way to build one
by accident, because it silently changes the content width of the thing it belongs to.

---

## What a swipe actually costs on this board, measured

Four suspects were tested against the same benchmark and **none of them was the answer.** Written
down so nobody spends another evening on them.

The instrument: `display_draw_stats()` reports repainted pixels and LVGL-task busy time on every
`hello` (see `ui/display.c`), and `ui_scroll_benchmark()` drives the carousel end to end so the swipe
is identical every run. `kpx per CPU-second` is the comparable number — it divides out how long the
run happened to take and says how expensive a pixel is.

| What was on screen / what changed | kpx per CPU-second | cycles/px |
|---|---:|---:|
| Overview + the empty page (no project tiles) | 4649 | 52 |
| Three project tiles | 2339 | 103 |
| …engine mark drawn 1:1 instead of scaled 1.4× | 2408 | 100 |
| …projects sent with **no recap** (almost no text) | 2391 | 100 |
| …LVGL's own perf-monitor overlay switched off | 2534 | 95 |
| …both wrapping labels given an absolute width | 2578 | 93 |

**The conclusion is the first row, not the rest.** Drawing a project tile costs about twice as much
per pixel as drawing an empty page, and nothing tried moved that by more than 5%. It is not the image
transform, not the text volume, not the debug overlay, and not the re-wrap loop above — all four are
real and all four are noise at this scale.

**The ceiling this implies.** 480×480 is 230,400 px. At 93 cycles/px on a 240 MHz core, one
full-screen repaint is ~90 ms — about **11 fps**, with the CPU saturated. The cheap case (52
cycles/px) is ~20 fps. So *no arrangement of this code can repaint the whole screen smoothly*: a
smooth swipe has to repaint LESS, not faster.

**Where the next attempt should go.** `tileview` is `lv_pct(100)`, so a swipe invalidates the whole
screen — including the status band (480×64) and the action bar (442×59), ~25% of every frame, neither
of which moves. The mockup's own words are "fixed bands, so swiping moves **content**, never the
frame". Sizing the tileview to the gap between them (y 64..402) and shifting the tiles' internal
offsets by the same 64 would take that 25% out of every swipe frame. It is a real change to a layout
that currently matches the mockup pixel for pixel, so it wants its own pass and its own before/after
on this same benchmark — not a guess bolted onto something else.

**One caveat on the benchmark itself.** It drives an *animated* scroll back to back with no idle gaps,
so saturating the CPU is expected and is not by itself evidence of stutter. A finger drag pauses,
samples touch, and re-materialises tiles. The number a finger produces is the one that settles it.
