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
