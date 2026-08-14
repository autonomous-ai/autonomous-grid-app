#include "ui_screens.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"   // BSP_LCD_H_RES / V_RES — every geometry constant below derives from these
#include "display.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "ui";

// Fonts are generated C arrays (ui/geist_*.c) linked into this component; LVGL wants a pointer to the
// lv_font_t they define. Declared here rather than in a header because the set a screen uses is a
// property of the screen, and a shared "all fonts" header is how every font ends up in every build.
//
// The sizes are the reference firmware's, unchanged. See the note in ui_screens.h: that file is the
// 720px board's layout already brought down to 480 with TYPE SCALED TO MATCH, and picking a face by role
// instead of taking the pair it was scaled into is the bug it records.
extern const lv_font_t geist_reg_13;   // meta: the agent and model under the name, the step line
extern const lv_font_t geist_reg_16;   // body: what the agent is saying right now
extern const lv_font_t geist_reg_24;   // the recap — the answer you read
extern const lv_font_t geist_reg_25;   // placeholders ("No activity yet") and the disconnected hint
extern const lv_font_t geist_med_21;   // the status verb
extern const lv_font_t geist_med_25;   // the project name; the disconnected headline

// ── PALETTE ─────────────────────────────────────────────────────────────────────────────────────────
// Borrowed whole from the reference, including the reason: the neutrals are WARM, and the point of that
// is not the colour but the CONTRAST. Pure white on pure black measures ~17.5:1, which is high enough to
// cause halation — the pupil opens for the black field and the type blooms. These land near 11.8:1,
// inside the band the dark-mode legibility work settles on.
//
// The ACCENTS are untouched by that warming: amber, red and green carry meaning rather than mood, and an
// accent that drifted with the palette would stop meaning the one thing it is for.
#define COL_BG       lv_color_hex(0x110e0a)   // not lv_color_black(): one step under the card on the same
                                              // warm ramp, keeping the separation black had from it
#define COL_FG       lv_color_hex(0xdbd1c0)
#define COL_INK_MID  lv_color_hex(0xa49c8d)   // the rung between FG and MUTED — the project name
#define COL_MUTED    lv_color_hex(0x898173)
#define COL_INK_LOW  lv_color_hex(0x6e675a)   // eyebrows, meta, placeholders
#define COL_HAIRLINE lv_color_hex(0x35302a)
#define COL_YELLOW   lv_color_hex(0xf0b429)   // a turn in progress. NOT green: green on this device means
                                              // live/connected/done, and reusing it makes the two states
                                              // indistinguishable at a glance
#define COL_RED      lv_color_hex(0xff5a5a)
#define COL_DOT_OFF  lv_color_hex(0x4c463c)   // inactive page dot

// ── GEOMETRY ────────────────────────────────────────────────────────────────────────────────────────
// Anything geometric is expressed against SCR_W/SCR_H rather than written as a literal. The values are
// the reference's, VERBATIM — that file is already the 480px port, so re-scaling them would be the bug
// its header records, applied a second time in the opposite direction.
#define SCR_W        BSP_LCD_H_RES
#define SCR_H        BSP_LCD_V_RES

#define SCREEN_PAD   19                       // 28 @720 — the margin reads the same at every size
#define ROW_W        (SCR_W - 2 * SCREEN_PAD)

// THE BANDS of a project tile. Fixed, so nothing moves when you swipe between projects or when a turn
// starts — only the well's CONTENTS change. That is the whole reason for banding it: a layout that
// re-centres itself per state makes every state change look like a different screen.
//
//    0 ..  64   header   project name · agent · model
//   81 .. 370   the well the recap, or the running turn
//  384 .. 450   actions  Stop, and only while a turn is running
//  450 .. 480   dots     one per project
#define BAND_H       64
#define WELL_Y       (BAND_H + 17)
#define DOTS_H       30
// A FINGERTIP, and fingertips do not scale with the panel. The reference holds its tap rows at 66 on
// both of its boards for exactly this reason; scaling that by 0.667 for a smaller screen produces a 44px
// target nobody can hit reliably.
#define ACT_H        66
#define ACT_Y        (SCR_H - DOTS_H - ACT_H)
#define WELL_BOT     (ACT_Y - 14)             // the action band starts at ACT_Y and they must not touch
#define WELL_H       (WELL_BOT - WELL_Y)

// WHAT ACTUALLY SCROLLS — and it is not the whole screen.
//
// The header band lives on the SCREEN, above the carousel, and is repainted when a swipe settles. It
// used to live inside each tile, on the reasoning that a per-tile header "costs nothing" and lets the
// name travel with the tile under your finger. It cost the scroll area: a header inside the tile makes
// the tile full-height, which makes the carousel full-screen, which makes every frame of a swipe redraw
// 480x480 into a PSRAM frame buffer the panel is scanning at the same time. On the bench that read as a
// stuttering, flickering swipe.
//
// Excluding the band and the dots takes the scrolled area to roughly 480x385 — about a fifth fewer
// pixels per frame, and the reference firmware (which swipes smoothly on this same board) reaches the
// same conclusion in its own words: "The identity is in the SHARED band now, so it does not arrive
// with the tile."
#define CAROUSEL_Y   (BAND_H + 1)                       // clears the band and its hairline
#define CAROUSEL_H   (SCR_H - CAROUSEL_Y - DOTS_H)
// Tile-local Y for the two bands that used to be positioned against the screen.
#define WELL_Y_IN    (WELL_Y - CAROUSEL_Y)
#define ACT_Y_IN     (ACT_Y - CAROUSEL_Y)

// The "processing" indicator: this many dots, blinking in sequence. The reference's number.
//
// Deliberately not the vendored ui/spinner_spokes.c, whose 12 pre-rotated frames exist because
// lv_obj_set_style_transform_rotation() snapshots the object to a temporary layer on every repaint —
// twelve of those ~14 times a second saturated the LVGL task on this panel and tripped the task watchdog
// every 5 seconds. Those assets carry no usage anywhere to copy the ring geometry from, and this screen
// cannot be checked by eye from here, so three dots it is: a guessed spinner that renders wrong looks
// exactly like a broken device.
#define BUSY_DOTS    3
#define BUSY_DOT_PX  8
#define BUSY_TICK_MS 300

// One tile: the model the protocol delivers, the live turn state, and the LVGL objects drawing them.
//
// The turn strings live HERE rather than in the message layer because they are the picture, not the
// protocol — panel_client hands over the last passage and the last step and keeps nothing.
typedef struct {
    ui_project_t p;
    char say[UI_ACTIVITY_MAX];       // last passage the agent wrote this turn
    char step[UI_ACTIVITY_MAX];      // last step it ran this turn
    bool failed;                     // the standing line is an error, and is drawn in the error colour

    lv_obj_t *tile;
    lv_obj_t *recap_box;             // the scrolling well contents; hidden as a whole while busy
    lv_obj_t *recap_lbl;             // the standing line — recap, error, or the empty placeholder
    lv_obj_t *busy;                  // the whole working block; hidden while idle
    lv_obj_t *dots[BUSY_DOTS];
    lv_obj_t *say_lbl;
    lv_obj_t *step_lbl;
    lv_obj_t *stop_btn;
    lv_obj_t *page_dot;              // this project's dot in the bottom strip
} tile_t;

// PSRAM BSS (CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY is on). ~15 KB of model, and internal RAM is
// the scarce one on this board — the framing layer already spends ~16 KB of it on its two 8 KB buffers.
// A static array rather than an allocation for the same reason panel_frame gives: a failed malloc
// mid-session on a microcontroller is a worse outcome than a known, always-paid cost.
static EXT_RAM_BSS_ATTR tile_t s_tiles[UI_MAX_PROJECTS];
static int s_count;
static int s_active;

static lv_obj_t *s_status_scr;      // "Not connected" / version mismatch / connected-but-empty
static lv_obj_t *s_status_title;
static lv_obj_t *s_status_hint;

static lv_obj_t *s_tiles_scr;
static lv_obj_t *s_carousel;
static lv_obj_t *s_page_dots;
// The shared header band: ONE name and ONE meta line for the whole carousel, repainted when a swipe
// settles. See CAROUSEL_Y for why these are not per tile.
static lv_obj_t *s_hdr_name;
static lv_obj_t *s_hdr_meta;

static bool s_connected;
static char s_machine[UI_NAME_MAX];
static void (*s_stop_cb)(const char *project_id);

static void set_hidden(lv_obj_t *o, bool hide);

// Repaint the shared band from whichever tile is centred.
//
// Separate from paint_tile because the band is not part of any tile: painting it there would let every
// tile in turn write its own name into the one header, and the last one repainted would win regardless
// of what the user is looking at.
static void paint_header(void)
{
    if (!s_hdr_name) return;
    if (s_active < 0 || s_active >= s_count) {
        lv_label_set_text(s_hdr_name, "");
        set_hidden(s_hdr_meta, true);
        return;
    }
    const ui_project_t *p = &s_tiles[s_active].p;
    lv_label_set_text(s_hdr_name, p->name[0] ? p->name : p->id);

    // "claude · auto", "claude", or nothing at all. protocol.md omits `agent` and `model` rather than
    // sending null when they are absent, so an empty string here means the app did not say — and a
    // separator with nothing on one side of it would invent a fact.
    char meta[UI_AGENT_MAX + UI_MODEL_MAX + 8];
    if (p->agent[0] && p->model[0]) snprintf(meta, sizeof(meta), "%s · %s", p->agent, p->model);
    else if (p->agent[0])           snprintf(meta, sizeof(meta), "%s", p->agent);
    else if (p->model[0])           snprintf(meta, sizeof(meta), "%s", p->model);
    else                            meta[0] = '\0';
    lv_label_set_text(s_hdr_meta, meta);
    set_hidden(s_hdr_meta, meta[0] == '\0');
}

static void paint_tile(int i);
static void show_right_screen(void);

// ── SMALL HELPERS ───────────────────────────────────────────────────────────────────────────────────

// See the header for why the codepoint boundary matters. Public because the message layer fills the
// model this file draws, and a byte-boundary clip there would arrive here already broken.
void ui_text_clip(char *dst, size_t cap, const char *src)
{
    if (cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    size_t n = strlen(src);
    if (n >= cap) {
        n = cap - 1;
        while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static void set_hidden(lv_obj_t *o, bool hide)
{
    if (!o) return;
    if (hide) lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
    else      lv_obj_remove_flag(o, LV_OBJ_FLAG_HIDDEN);
}

static int find_project(const char *id)
{
    if (!id || !id[0]) return -1;
    for (int i = 0; i < s_count; i++)
        if (strcmp(s_tiles[i].p.id, id) == 0) return i;
    return -1;
}

// ── THE STATUS SCREEN ───────────────────────────────────────────────────────────────────────────────

// Two lines, and the second one is not decoration. A headline on its own leaves the reader with nowhere
// to go — and on this device the answer usually is that simple, because the cable IS the connection:
// there is no network to check, no pairing to redo, no account to sign into.
static void status_show(const char *title, const char *hint)
{
    lv_label_set_text(s_status_title, title);
    lv_label_set_text(s_status_hint, hint);
    if (lv_screen_active() != s_status_scr) lv_screen_load(s_status_scr);
}

static void build_status_screen(void)
{
    s_status_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_status_scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(s_status_scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(s_status_scr, LV_OBJ_FLAG_SCROLLABLE);

    s_status_title = lv_label_create(s_status_scr);
    lv_obj_set_style_text_font(s_status_title, &geist_med_25, 0);
    lv_obj_set_style_text_color(s_status_title, COL_FG, 0);
    lv_obj_align(s_status_title, LV_ALIGN_CENTER, 0, -16);
    lv_label_set_text(s_status_title, "");

    s_status_hint = lv_label_create(s_status_scr);
    lv_obj_set_style_text_font(s_status_hint, &geist_reg_16, 0);
    lv_obj_set_style_text_color(s_status_hint, COL_MUTED, 0);
    // Wrapped rather than one long line: the panel is 480 px wide and the sentence is not guaranteed to
    // fit at every future wording. A label that overflows its screen truncates silently.
    lv_obj_set_width(s_status_hint, SCR_W - 2 * 40);
    lv_label_set_long_mode(s_status_hint, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_align(s_status_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_status_hint, LV_ALIGN_CENTER, 0, 24);
    lv_label_set_text(s_status_hint, "");
}

// ── THE CAROUSEL ────────────────────────────────────────────────────────────────────────────────────

static int active_column(void)
{
    if (!s_carousel) return 0;
    int32_t sx = lv_obj_get_scroll_x(s_carousel);
    return (int)((sx + SCR_W / 2) / SCR_W);
}

static void paint_page_dots(void)
{
    for (int i = 0; i < s_count; i++) {
        if (!s_tiles[i].page_dot) continue;
        lv_obj_set_style_bg_color(s_tiles[i].page_dot, i == s_active ? COL_FG : COL_DOT_OFF, 0);
    }
}

static void carousel_settled(lv_event_t *e)
{
    (void)e;
    if (s_count <= 0) return;
    int col = active_column();
    if (col < 0) col = 0;
    if (col >= s_count) col = s_count - 1;
    if (col == s_active) return;
    s_active = col;
    paint_page_dots();
    paint_header();
}

static void stop_tap(lv_event_t *e)
{
    int i = (int)(intptr_t)lv_event_get_user_data(e);
    if (i < 0 || i >= s_count) return;
    ESP_LOGI(TAG, "stop pressed on project %s", s_tiles[i].p.id);
    // Fire even when the tile no longer looks busy. The user pressed the thing that was on screen, and a
    // stop for a turn that has just ended is harmless on the app side; swallowing the press because a
    // `turn.done` landed a frame earlier is how an interrupt button earns a reputation for not working.
    if (s_stop_cb) s_stop_cb(s_tiles[i].p.id);
}

// One dot of the "processing" indicator.
static lv_obj_t *make_busy_dot(lv_obj_t *parent)
{
    lv_obj_t *d = lv_obj_create(parent);
    lv_obj_remove_style_all(d);
    lv_obj_remove_flag(d, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(d, BUSY_DOT_PX, BUSY_DOT_PX);
    lv_obj_set_style_radius(d, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(d, COL_YELLOW, 0);
    lv_obj_set_style_bg_opa(d, LV_OPA_30, 0);
    return d;
}

static void build_tile(int i)
{
    tile_t *t = &s_tiles[i];

    t->tile = lv_obj_create(s_carousel);
    lv_obj_set_size(t->tile, SCR_W, CAROUSEL_H);
    lv_obj_set_style_border_width(t->tile, 0, 0);
    lv_obj_set_style_radius(t->tile, 0, 0);
    lv_obj_set_style_bg_color(t->tile, COL_BG, 0);
    lv_obj_set_style_pad_all(t->tile, 0, 0);
    // NO flex on the tile: each band is placed at a fixed Y and fills the column. A centred flex column
    // shrinks to its content and parks in the middle, which is what made the reference's first port read
    // as a small cluster adrift in a large void.
    lv_obj_remove_flag(t->tile, LV_OBJ_FLAG_SCROLLABLE);

    // HEADER — name, then the agent and model that annotate it.
    //
    // The reference keeps ONE header for the whole carousel in a fixed band and repoints it on every
    // swipe, because it materialises tiles lazily and a per-tile copy would be rebuilt on every window
    // The header is NOT here — it is one shared band on the screen above this carousel. See CAROUSEL_Y.

    // THE WELL — fixed position AND height, not LV_SIZE_CONTENT. Content-sizing lets the recap shrink to
    // its text and float; fixed means the frame is identical for a one-line answer, a ten-line one, and a
    // running turn.
    lv_obj_t *well = lv_obj_create(t->tile);
    lv_obj_remove_style_all(well);
    lv_obj_set_size(well, ROW_W, WELL_H);
    lv_obj_align(well, LV_ALIGN_TOP_MID, 0, WELL_Y_IN);
    lv_obj_remove_flag(well, LV_OBJ_FLAG_SCROLLABLE);

    // Idle: the standing line, in a box that SCROLLS vertically.
    //
    // The well is 289px and a recap can be a paragraph — around five lines fit. A fixed-height label
    // would clip the rest with nothing on screen to say it had, which is the one failure mode a recap
    // cannot have: the missing part is the end of the sentence. Vertical only, because the parent
    // carousel owns horizontal and a box that grabbed both would fight every swipe.
    lv_obj_t *recap_box = lv_obj_create(well);
    t->recap_box = recap_box;
    lv_obj_remove_style_all(recap_box);
    // Absolute too, matching the well it fills. Same reason as the label below: a percentage here would
    // put one more resolve-against-the-parent step inside the scroll path, and the reference's own header
    // says every geometric value is expressed against SCR_W/SCR_H rather than left to resolve at draw.
    lv_obj_set_size(recap_box, ROW_W, WELL_H);
    lv_obj_align(recap_box, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_set_scroll_dir(recap_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(recap_box, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_style_bg_color(recap_box, COL_INK_LOW, LV_PART_SCROLLBAR);
    lv_obj_set_style_bg_opa(recap_box, LV_OPA_COVER, LV_PART_SCROLLBAR);
    lv_obj_set_style_width(recap_box, 3, LV_PART_SCROLLBAR);
    lv_obj_set_style_radius(recap_box, LV_RADIUS_CIRCLE, LV_PART_SCROLLBAR);

    // Left-aligned, because a finished answer is read line by line and wants a straight left edge.
    t->recap_lbl = lv_label_create(recap_box);
    // ABSOLUTE width, never lv_pct(100), and the reason is a feedback loop rather than a preference.
    // A percentage resolves against the box's *content* width, which shrinks when the AUTO scrollbar
    // appears. Narrower content re-wraps this label, re-wrapping changes its height, and its height is
    // what decides whether the scrollbar is needed at all — so the two chase each other, re-measuring
    // every glyph of the recap in Geist on each pass. On screen that reads as the whole tile flickering
    // and the swipe stuttering, which is exactly what it did.
    //
    // ROW_W less the 3px scrollbar and a little air. Fixed, so the wrap is computed once and a
    // scrollbar appearing changes nothing about the text.
    lv_obj_set_width(t->recap_lbl, ROW_W - 8);
    lv_obj_set_height(t->recap_lbl, LV_SIZE_CONTENT);   // grows past the box; the box scrolls to it
    lv_obj_align(t->recap_lbl, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_label_set_long_mode(t->recap_lbl, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_font(t->recap_lbl, &geist_reg_24, 0);
    lv_obj_set_style_text_color(t->recap_lbl, COL_MUTED, 0);
    // 1.75 line height, which is what a Kindle sets — geist_reg_24 reports a 49px line, so +10 lands on
    // 59px. Loose leading is most of why a page of a book does not feel like a wall of text, and it
    // matters more here because the column runs the full width of the panel.
    lv_obj_set_style_text_line_space(t->recap_lbl, 10, 0);
    lv_label_set_text(t->recap_lbl, "");

    // Running: the working block. CENTRED, unlike the recap's prose — a live turn is a two-line status
    // readout, and centring keeps the eye in one place while the words underneath keep changing.
    t->busy = lv_obj_create(well);
    lv_obj_remove_style_all(t->busy);
    lv_obj_remove_flag(t->busy, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(t->busy, lv_pct(100), lv_pct(100));
    lv_obj_set_flex_flow(t->busy, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(t->busy, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(t->busy, 16, 0);
    lv_obj_add_flag(t->busy, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *dotrow = lv_obj_create(t->busy);
    lv_obj_remove_style_all(dotrow);
    lv_obj_remove_flag(dotrow, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(dotrow, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(dotrow, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(dotrow, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(dotrow, 10, 0);
    for (int k = 0; k < BUSY_DOTS; k++) t->dots[k] = make_busy_dot(dotrow);

    t->say_lbl = lv_label_create(t->busy);
    lv_obj_set_width(t->say_lbl, lv_pct(100));
    // THREE lines, then dots. A passage can be a paragraph, and this block is centred in the well — a
    // label free to grow would push the dot row off the top of it and take the one indicator that says
    // the turn is still alive with it. The recap gets a scroll box because a finished answer is meant to
    // be read; a live passage is replaced within seconds and is not.
    //
    // Derived from the face rather than typed, so it stays three lines if the font ever moves.
    lv_obj_set_height(t->say_lbl, 3 * (lv_font_get_line_height(&geist_reg_16) + 6));
    lv_label_set_long_mode(t->say_lbl, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_style_text_font(t->say_lbl, &geist_reg_16, 0);
    lv_obj_set_style_text_color(t->say_lbl, COL_FG, 0);
    lv_obj_set_style_text_align(t->say_lbl, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_line_space(t->say_lbl, 6, 0);
    lv_label_set_text(t->say_lbl, "");

    t->step_lbl = lv_label_create(t->busy);
    lv_obj_set_width(t->step_lbl, lv_pct(100));
    // ONE line, clipped with dots. A step label is a command line and can be arbitrarily long; wrapping
    // one would push the passage above it off the centre it was placed on.
    lv_label_set_long_mode(t->step_lbl, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_style_text_font(t->step_lbl, &geist_reg_13, 0);
    lv_obj_set_style_text_color(t->step_lbl, COL_INK_LOW, 0);
    lv_obj_set_style_text_align(t->step_lbl, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(t->step_lbl, "");

    // STOP — the one write path this firmware has. A full-width pill so the target is unmissable, and
    // present only while there is something to interrupt: a button that does nothing when pressed is
    // worse than no button, because it teaches the user that pressing it does nothing.
    t->stop_btn = lv_button_create(t->tile);
    lv_obj_set_size(t->stop_btn, ROW_W, ACT_H);
    lv_obj_align(t->stop_btn, LV_ALIGN_TOP_MID, 0, ACT_Y_IN);
    lv_obj_set_style_radius(t->stop_btn, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(t->stop_btn, COL_RED, 0);
    lv_obj_set_style_bg_opa(t->stop_btn, LV_OPA_20, 0);
    lv_obj_set_style_bg_opa(t->stop_btn, LV_OPA_40, LV_STATE_PRESSED);
    lv_obj_set_style_border_width(t->stop_btn, 1, 0);
    lv_obj_set_style_border_color(t->stop_btn, COL_RED, 0);
    lv_obj_add_event_cb(t->stop_btn, stop_tap, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    lv_obj_add_flag(t->stop_btn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_t *stop_lbl = lv_label_create(t->stop_btn);
    lv_label_set_text(stop_lbl, "Stop");
    lv_obj_set_style_text_font(stop_lbl, &geist_med_21, 0);
    lv_obj_set_style_text_color(stop_lbl, COL_RED, 0);
    lv_obj_center(stop_lbl);

    // This project's page dot. Lives on the screen, not the tile — it must stay put while the tiles move.
    t->page_dot = lv_obj_create(s_page_dots);
    lv_obj_remove_style_all(t->page_dot);
    lv_obj_remove_flag(t->page_dot, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(t->page_dot, 8, 8);
    lv_obj_set_style_radius(t->page_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(t->page_dot, COL_DOT_OFF, 0);
    lv_obj_set_style_bg_opa(t->page_dot, LV_OPA_COVER, 0);
}

static void build_tiles_screen(void)
{
    s_tiles_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_tiles_scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(s_tiles_scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(s_tiles_scr, LV_OBJ_FLAG_SCROLLABLE);

    // A plain horizontally-scrollable container, NOT lv_tileview. Paging comes from SCROLL_SNAP_CENTER
    // plus SCROLL_ONE — exactly what lv_tileview does internally, so the feel is identical — and a plain
    // object is something the rest of this file can position children in without fighting a widget.
    // THE SHARED HEADER BAND — on the screen, above the carousel, so a swipe never redraws it.
    lv_obj_t *hdr = lv_obj_create(s_tiles_scr);
    lv_obj_remove_style_all(hdr);
    lv_obj_remove_flag(hdr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(hdr, ROW_W, BAND_H);
    lv_obj_align(hdr, LV_ALIGN_TOP_MID, 0, 0);
    lv_obj_set_flex_flow(hdr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(hdr, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    s_hdr_name = lv_label_create(hdr);
    lv_obj_set_width(s_hdr_name, ROW_W);
    lv_obj_set_style_text_font(s_hdr_name, &geist_med_25, 0);
    // INK_MID, not FG: the recap is the answer and keeps the brighter ink, so the glance lands there.
    lv_obj_set_style_text_color(s_hdr_name, COL_INK_MID, 0);
    lv_label_set_long_mode(s_hdr_name, LV_LABEL_LONG_MODE_DOTS);
    lv_label_set_text(s_hdr_name, "");

    s_hdr_meta = lv_label_create(hdr);
    lv_obj_set_width(s_hdr_meta, ROW_W);
    lv_obj_set_style_text_font(s_hdr_meta, &geist_reg_13, 0);
    lv_obj_set_style_text_color(s_hdr_meta, COL_INK_LOW, 0);
    lv_label_set_long_mode(s_hdr_meta, LV_LABEL_LONG_MODE_DOTS);
    lv_label_set_text(s_hdr_meta, "");

    // A hairline under the band. One pixel doing the work a third type size would, which is a size this
    // board's font set does not have to spend.
    lv_obj_t *rule = lv_obj_create(s_tiles_scr);
    lv_obj_remove_style_all(rule);
    lv_obj_remove_flag(rule, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(rule, ROW_W, 1);
    lv_obj_align(rule, LV_ALIGN_TOP_MID, 0, BAND_H);
    lv_obj_set_style_bg_color(rule, COL_HAIRLINE, 0);
    lv_obj_set_style_bg_opa(rule, LV_OPA_COVER, 0);

    s_carousel = lv_obj_create(s_tiles_scr);
    lv_obj_set_size(s_carousel, SCR_W, CAROUSEL_H);
    lv_obj_align(s_carousel, LV_ALIGN_TOP_LEFT, 0, CAROUSEL_Y);
    lv_obj_set_style_bg_color(s_carousel, COL_BG, 0);
    lv_obj_set_style_pad_all(s_carousel, 0, 0);
    lv_obj_set_style_pad_column(s_carousel, 0, 0);
    lv_obj_set_style_border_width(s_carousel, 0, 0);
    lv_obj_set_style_radius(s_carousel, 0, 0);
    lv_obj_set_scrollbar_mode(s_carousel, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_flex_flow(s_carousel, LV_FLEX_FLOW_ROW);
    lv_obj_set_scroll_dir(s_carousel, LV_DIR_HOR);
    lv_obj_set_scroll_snap_x(s_carousel, LV_SCROLL_SNAP_CENTER);   // always land a tile centred
    lv_obj_add_flag(s_carousel, LV_OBJ_FLAG_SCROLL_ONE);           // one tile per swipe, no free drift
    lv_obj_remove_flag(s_carousel, LV_OBJ_FLAG_SCROLL_ELASTIC);    // no edge over-scroll
    lv_obj_add_event_cb(s_carousel, carousel_settled, LV_EVENT_SCROLL_END, NULL);

    s_page_dots = lv_obj_create(s_tiles_scr);
    lv_obj_remove_style_all(s_page_dots);
    lv_obj_remove_flag(s_page_dots, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(s_page_dots, SCR_W, DOTS_H);
    lv_obj_align(s_page_dots, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_set_flex_flow(s_page_dots, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_page_dots, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(s_page_dots, 8, 0);
}

// Delete every tile. LVGL frees a subtree with its parent, so the tile objects go with the carousel's
// children; the page dots are on the screen and have to be cleaned separately.
static void clear_tiles(void)
{
    if (s_carousel)  lv_obj_clean(s_carousel);
    if (s_page_dots) lv_obj_clean(s_page_dots);
    memset(s_tiles, 0, sizeof(s_tiles));
    s_count  = 0;
    s_active = 0;
}

// ── PAINTING ────────────────────────────────────────────────────────────────────────────────────────

static void paint_tile(int i)
{
    tile_t *t = &s_tiles[i];
    if (!t->tile) return;
    if (i == s_active) paint_header();

    if (t->p.busy) {
        set_hidden(t->recap_box, true);
        set_hidden(t->busy, false);
        // "Working…" until the agent says something. An empty well under three blinking dots reads as a
        // panel that has lost its place, which is the opposite of what the dots are there to say.
        lv_label_set_text(t->say_lbl, t->say[0] ? t->say : "Working…");
        lv_obj_set_style_text_color(t->say_lbl, t->say[0] ? COL_FG : COL_YELLOW, 0);
        lv_label_set_text(t->step_lbl, t->step);
        set_hidden(t->step_lbl, t->step[0] == '\0');
        set_hidden(t->stop_btn, false);
    } else {
        set_hidden(t->busy, true);
        set_hidden(t->stop_btn, true);
        set_hidden(t->recap_box, false);
        const char *line = t->p.recap[0] ? t->p.recap : "No activity yet";
        lv_label_set_text(t->recap_lbl, line);
        // An error keeps its colour; a recap that is really the placeholder is dimmed so the eye skips
        // it. Both are decisions about what the line MEANS, which is why they are made here rather than
        // baked into the label at build time.
        lv_obj_set_style_text_color(t->recap_lbl,
                                    t->failed ? COL_RED : (t->p.recap[0] ? COL_MUTED : COL_INK_LOW), 0);
        lv_obj_set_style_text_font(t->recap_lbl,
                                   t->p.recap[0] ? &geist_reg_24 : &geist_reg_25, 0);
    }
}

// The blink. One timer for the whole screen: only one tile is ever visible, so animating the others
// would be work nobody can see.
static void busy_tick(lv_timer_t *timer)
{
    (void)timer;
    if (lv_screen_active() != s_tiles_scr) return;
    if (s_active < 0 || s_active >= s_count) return;
    tile_t *t = &s_tiles[s_active];
    if (!t->p.busy || !t->dots[0]) return;

    // A turn running on the desktop produces NO touch on this panel, so the idle timer would blank the
    // screen in the middle of the one thing the device exists to show. Count a running turn as activity.
    display_bump_activity();

    static int phase;
    phase = (phase + 1) % BUSY_DOTS;
    for (int k = 0; k < BUSY_DOTS; k++)
        lv_obj_set_style_bg_opa(t->dots[k], k == phase ? LV_OPA_COVER : LV_OPA_30, 0);
}

// Which screen the current state calls for. One place decides, so a state can never be reachable by two
// paths that disagree about what it looks like.
static void show_right_screen(void)
{
    if (!s_connected) {
        status_show("Not connected", "Plug into a computer running grid-app");
        return;
    }
    if (s_count == 0) {
        // Honest about which half is empty: the link is up, so this is grid-app reporting no projects,
        // not the panel failing to ask.
        char hint[96];
        snprintf(hint, sizeof(hint), "%s has no projects open",
                 s_machine[0] ? s_machine : "This computer");
        status_show("Nothing to show", hint);
        return;
    }
    if (lv_screen_active() != s_tiles_scr) lv_screen_load(s_tiles_scr);
}

// ── PUBLIC API ──────────────────────────────────────────────────────────────────────────────────────

void ui_screens_init(void)
{
    build_status_screen();
    build_tiles_screen();
    lv_timer_create(busy_tick, BUSY_TICK_MS, NULL);
    s_connected = false;
    show_right_screen();
    ESP_LOGI(TAG, "screens ready");
}

void ui_set_stop_cb(void (*cb)(const char *project_id))
{
    s_stop_cb = cb;
}

void ui_set_connected(bool connected, const char *machine_name)
{
    if (connected) ui_text_clip(s_machine, sizeof(s_machine), machine_name);
    else           s_machine[0] = '\0';

    if (s_connected == connected) { show_right_screen(); return; }
    s_connected = connected;
    // See the header: the tiles go with the link. Every line on them is a claim about a machine this
    // panel can no longer see.
    if (!connected) clear_tiles();
    ESP_LOGI(TAG, "link %s%s%s", connected ? "up" : "down",
             s_machine[0] ? " — " : "", s_machine[0] ? s_machine : "");
    show_right_screen();
}

void ui_show_version_mismatch(int app_proto, int panel_proto)
{
    s_connected = false;
    clear_tiles();
    char hint[128];
    // Name both numbers, and take the panel's own from the caller rather than hardcoding it here: the
    // message-layer version belongs to the message layer, and a second copy of it in the UI is a copy
    // that will one day disagree. "Update needed" on its own tells the reader nothing they can carry to
    // the machine, and this is the one failure the app can actually fix — it holds the firmware image.
    snprintf(hint, sizeof(hint),
             "grid-app speaks protocol %d, this panel speaks %d. Reflash the panel from grid-app.",
             app_proto, panel_proto);
    status_show("Panel needs an update", hint);
}

void ui_projects_replace(const ui_project_t *items, int count)
{
    // Remember what the user is LOOKING at, not which column it was in. `projects` is sent whole on
    // every change, so a project appearing or being closed anywhere in the list shifts every column
    // after it — restoring by index would silently swap the tile under someone's eyes for its
    // neighbour, which is worse than jumping home.
    char was_looking_at[UI_ID_MAX];
    ui_text_clip(was_looking_at, sizeof(was_looking_at),
                 (s_active >= 0 && s_active < s_count) ? s_tiles[s_active].p.id : "");

    clear_tiles();
    if (count > UI_MAX_PROJECTS) {
        // Loudly, not silently: a cap that drops work without saying so is indistinguishable from a bug
        // in the app that sent it.
        ESP_LOGW(TAG, "%d projects, showing the first %d", count, UI_MAX_PROJECTS);
        count = UI_MAX_PROJECTS;
    }
    for (int i = 0; i < count; i++) {
        s_tiles[i].p = items[i];
        build_tile(i);
        s_count = i + 1;
        paint_tile(i);
    }

    int restore = find_project(was_looking_at);
    s_active = restore > 0 ? restore : 0;
    // No animation: this is not the user moving, it is the list being replaced under a view that must
    // not appear to move at all.
    if (s_carousel) lv_obj_scroll_to_x(s_carousel, s_active * SCR_W, LV_ANIM_OFF);
    paint_page_dots();
    show_right_screen();
    ESP_LOGI(TAG, "projects: %d tile(s)", s_count);
}

void ui_project_update(const ui_project_t *item)
{
    if (!item) return;
    int i = find_project(item->id);
    if (i < 0) {
        // A project the panel has not heard of. Appending beats ignoring: `project.updated` is how a
        // project created on the desktop reaches a panel that already has its list, and asking for the
        // whole list again would redraw every tile to learn about one.
        if (s_count >= UI_MAX_PROJECTS) {
            ESP_LOGW(TAG, "no room for a %dth project (%s)", s_count + 1, item->id);
            return;
        }
        i = s_count;
        s_tiles[i].p = *item;
        build_tile(i);
        s_count = i + 1;
        paint_tile(i);
        paint_page_dots();
        show_right_screen();
        return;
    }
    // A busy→idle transition ends the turn's live state whether or not a `turn.done` arrived. The two
    // messages carry the same fact from different directions and the panel must not be left blinking
    // because one of them was the only one sent.
    if (s_tiles[i].p.busy && !item->busy) {
        s_tiles[i].say[0] = '\0';
        s_tiles[i].step[0] = '\0';
    }
    s_tiles[i].p = *item;
    paint_tile(i);
}

void ui_project_turn_started(const char *project_id)
{
    int i = find_project(project_id);
    if (i < 0) return;
    s_tiles[i].p.busy = true;
    s_tiles[i].failed = false;
    s_tiles[i].say[0] = '\0';
    s_tiles[i].step[0] = '\0';
    // The previous recap goes NOW, not when the new one arrives. Leaving it under a live spinner puts
    // the last turn's answer next to this turn's progress, which reads as if the agent had already
    // replied.
    s_tiles[i].p.recap[0] = '\0';
    paint_tile(i);
}

void ui_project_turn_activity(const char *project_id, const char *say, const char *step)
{
    int i = find_project(project_id);
    if (i < 0) return;
    // Parts arrive whole on every change (protocol.md §2), so an update that carries no passage means
    // there is no passage yet — not that the previous one still stands.
    ui_text_clip(s_tiles[i].say,  sizeof(s_tiles[i].say),  say);
    ui_text_clip(s_tiles[i].step, sizeof(s_tiles[i].step), step);
    s_tiles[i].p.busy = true;
    paint_tile(i);
}

void ui_project_turn_done(const char *project_id, const char *recap)
{
    int i = find_project(project_id);
    if (i < 0) return;
    s_tiles[i].p.busy = false;
    s_tiles[i].failed = false;
    s_tiles[i].say[0] = '\0';
    s_tiles[i].step[0] = '\0';
    // An EMPTY recap is a real answer, not a missing one: protocol.md §2 says the key is always
    // present on turn.done and can be "" — a turn stopped before the assistant said anything. Falling
    // through to the "No activity yet" placeholder would deny the turn ever happened, so this state
    // gets its own words.
    ui_text_clip(s_tiles[i].p.recap, sizeof(s_tiles[i].p.recap),
                 (recap && recap[0]) ? recap : "Done. No summary.");
    paint_tile(i);
}

void ui_project_turn_error(const char *project_id, const char *message)
{
    int i = find_project(project_id);
    if (i < 0) return;
    s_tiles[i].p.busy = false;
    s_tiles[i].failed = true;
    s_tiles[i].say[0] = '\0';
    s_tiles[i].step[0] = '\0';
    // The message becomes the standing line. A turn that failed and shows the previous turn's recap is
    // the "reports a failure and reassures at once" bug: the tile would read as if it had succeeded.
    ui_text_clip(s_tiles[i].p.recap, sizeof(s_tiles[i].p.recap),
              (message && message[0]) ? message : "The turn failed");
    paint_tile(i);
}
