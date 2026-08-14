// The panel's screens.
//
// Three states, and the panel is always in exactly one of them:
//
//   NOT CONNECTED   no machine is talking to this panel — the cable is out, or grid-app is not running
//   MISMATCH        a machine is talking, but it speaks a different message-layer version
//   TILES           one swipeable tile per project
//
// The layout is borrowed from the reference firmware
// (autonomous-code/apps/esp32-square-s3/main/ui/ui_screens.c), which runs the SAME 480x480 board. That
// file's header states two scaling rules and records the bug behind them: it holds a 720px board's
// layout brought down to 480, PAGE GEOMETRY and TYPE were meant to scale together by 0.667, and a first
// pass scaled the boxes while reusing the round board's faces by role — a 41px row was then asked to
// hold a 35px line and most screens overflowed. FINGER SIZES do not scale at all: a row you tap is
// sized by a fingertip, which knows nothing about the panel.
//
// The consequence for THIS file is easy to get wrong in the other direction: the reference is ALREADY
// at 480, so every constant borrowed from it is taken VERBATIM. Re-applying 0.667 to a number that has
// already been through it is the same bug wearing the opposite sign. The one number below that is not
// from that file is ACT_H, and it is not scaled either — it is a fingertip.
//
// EVERY function here must be called with display_lock() held, or from the LVGL task. LVGL is not
// thread-safe and the failure is a corrupted display list rather than an error return.
#pragma once

#include <stdbool.h>
#include <stddef.h>

// Field caps. Sized from what a 480px tile can actually SHOW, not from what grid-app can hold: a project
// name that needs 80 characters is a name this screen was never going to render, and a recap longer than
// the well is scrolled, not stored. Clipping here rather than at draw time keeps the model the same size
// as the picture of it.
#define UI_ID_MAX        48
#define UI_NAME_MAX      64
#define UI_AGENT_MAX     24
#define UI_MODEL_MAX     32
#define UI_RECAP_MAX     256
// 200 characters is the app's own clip on a turn part (protocol.md §2), and 224 bytes holds that
// whole for Latin text. Vietnamese or CJK is 2–3 bytes a character and still gets cut — correctly,
// on a codepoint boundary — which is fine: a step label this long is already past what one line of a
// 480px tile can show.
#define UI_ACTIVITY_MAX  224

// How many tiles the carousel will hold.
//
// A hard cap, not a target. The reference firmware supports an unbounded agent count by materialising
// only the active tile ±1 and leaving an invisible spacer to hold the scroll range — real machinery that
// exists because its fleet can be large. A panel plugged into one desktop is looking at that desktop's
// projects, and a person with more than twelve open has a different problem than this screen can solve.
// Projects past the cap are dropped with a log line rather than silently, so the number is falsifiable.
#define UI_MAX_PROJECTS  12

// One project, exactly as a tile draws it — the protocol's project shape (docs/protocol.md §2) with the
// strings already bounded. `agent` and `model` may be empty: protocol.md omits them rather than sending
// null when absent, so "" here means "the app did not say", not "the app said nothing".
typedef struct {
    char id[UI_ID_MAX];
    char name[UI_NAME_MAX];
    char agent[UI_AGENT_MAX];
    char model[UI_MODEL_MAX];
    bool busy;
    char recap[UI_RECAP_MAX];
} ui_project_t;

// Copy `src` into `dst` (cap bytes including the NUL), cutting on a UTF-8 CODEPOINT boundary.
//
// A string utility in a UI header because the REASON is the font. These faces were generated with
// Vietnamese in their glyph ranges, and every accented Vietnamese character is two or three bytes — a
// plain strncpy that lands mid-character leaves a lone continuation byte, which LVGL draws as a
// missing-glyph box or swallows the character after it. The failure is silent and only visible on the
// panel, which is the worst place to find it. Every string that reaches a label goes through here.
//
// Safe to call from any task: it touches no LVGL state.
void ui_text_clip(char *dst, size_t cap, const char *src);

// Build the screens and show the disconnected state. Call once, after display_init().
void ui_screens_init(void);

// Register what a Stop press should do. Called with the project id of the tile the user pressed on.
//
// A callback rather than a direct call into panel_client because the direction of dependency has to run
// one way: the message layer knows about the screens, the screens know nothing about USB. The same UI
// then still builds and draws if the link is ever replaced or removed.
//
// The callback runs ON THE LVGL TASK with display_lock() held.
void ui_set_stop_cb(void (*cb)(const char *project_id));

// Link state. `machine_name` may be NULL or empty and is only used when connected.
//
// Going from connected to not-connected DROPS the tiles. Showing the last known project list under a
// "Not connected" banner would be worse than showing nothing: every line of it would be a claim about a
// machine this panel can no longer see, and a stale "Working…" is the exact lie docs/conventions.md §5
// calls a bug rather than a wording problem.
void ui_set_connected(bool connected, const char *machine_name);

// A machine is talking but speaks a different message-layer version.
//
// Its own state, not an error toast: protocol.md §2 makes this a state to display, because the app
// carries the firmware image and can offer to reflash the panel over the same cable it is complaining on.
void ui_show_version_mismatch(int app_proto, int panel_proto);

// Replace the whole tile model. `count` over UI_MAX_PROJECTS is clipped.
void ui_projects_replace(const ui_project_t *items, int count);

// Update one project in place, or append it if the id is new.
void ui_project_update(const ui_project_t *item);

// A turn began on this project — busy indicator on, previous recap cleared.
void ui_project_turn_started(const char *project_id);

// The live state of a running turn: the last passage the agent wrote and the last step it ran.
//
// TWO lines rather than the whole timeline. protocol.md sends `parts` whole on every change, in order,
// and the order is the message — but a 480px well cannot hold a timeline and re-rendering one on every
// update would spend the frame budget redrawing text that has not changed. The last of each kind is what
// a glance across a desk is actually asking for: what is it saying, and what is it doing. Either may be
// empty.
void ui_project_turn_activity(const char *project_id, const char *say, const char *step);

// The turn ended. `recap` becomes the tile's standing line.
void ui_project_turn_done(const char *project_id, const char *recap);

// The turn failed. Shown in place of the recap, in the error colour, until the next turn.
void ui_project_turn_error(const char *project_id, const char *message);
