// LVGL screens for the Grid Panel (square 480x480). Thread-safe: each function takes the LVGL lock
// internally (display_lock/unlock), so the USB link task may call them directly.
//
// This is the reference firmware's ui_screens.h with the screens this device does not have taken out —
// see the note at the top of ui_screens.c for the full list and why each one went. What remains is the
// carousel (Overview + one tile per project), the notification drawer, and the two states the link can
// fail into.
//
// THE VOCABULARY IS grid-app's, and it is the opposite of the reference's: here a `project` is the
// working unit with a workspace, and an `agent` is the runtime that answers in it. That firmware uses
// those two words the other way round. Do not copy its labels (docs/overview.md).
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>   // size_t (ui_project_id_at)

// Per-project Model/Effort chips in the header band. Kept from the reference, but DISPLAY ONLY: opening
// its picker needs a `models_list` RPC that grid-app does not have. Set to 0 to hide the chips entirely,
// which also re-widens touch.c's notification pull-zone (taps above the project name stop being claimed).
#define AGENT_CTL_CHIPS 1

void ui_init(void);

// --- Full-screen states ---
// The two things that can be on screen instead of the carousel. The reference has seven more — a setup
// chooser, a pairing code, a WiFi portal, an E2EE handshake — all of which answered "which network and
// whose account". Plugging the cable in answers both.
void ui_show_connecting(const char *step);
void ui_show_error(const char *title, const char *detail);
// The same screen, but it returns to the carousel on its own after a few seconds. For something that
// has already finished — a voice press that caught nothing — where staying put would be a screen stuck
// on old news.
void ui_show_notice(const char *title, const char *body);
// If the error screen is currently shown, return to the projects view (used when grid-app reconnects, so
// a transient drop doesn't leave the device stuck on a stale error).
void ui_leave_error_screen(void);

// --- The carousel: Overview at ring 0, then one tile per project ---
void ui_show_projects(void);
// Boot landing: park on the Overview tile (no "No projects" flash) and arm a landing so that once the
// first project list arrives, ui_land_after_reload slides to project 0 — or stays on Overview if empty.
void ui_enter_boot_loading(void);
void ui_land_after_reload(void);
// grid-app is not answering on the cable: clear stale tiles and show the Overview "open Grid" guide.
// When it answers again, switch the guide to the loading spinner; ui_land_after_reload restores the rest.
void ui_enter_remote_offline(void);
void ui_leave_remote_offline_loading(void);
// Whether `welcome` has been seen — drives the tile dots and the "Not connected" badge.
void ui_set_connected(bool connected);

// Ensure a tile exists for project_id (creates one if new) and set the name shown on it. Safe to call
// repeatedly — this is how the whole `projects` list is applied.
void ui_project_set_name(const char *project_id, const char *name);
// Set the engine mark shown beside the name. Invalid/empty values leave it blank.
void ui_project_set_engine(const char *project_id, const char *engine);
// The model the project runs on, as the opaque runtime-v1 profile the chips parse.
void ui_project_set_selected_model(const char *project_id, const char *runtime_id);

// Remove a project's tile. No-op if the id isn't shown.
void ui_project_remove(const char *project_id);
// Drop every tile (grid-app went away, or handed over a whole new list).
void ui_project_clear_all(void);
// Copy the id of the project tile at index i into buf; false if out of range (used to reconcile a list).
bool ui_project_id_at(int i, char *buf, size_t n);
int ui_project_count(void);
// Current focused project index, or -1 when the carousel is on Overview / empty.
int ui_get_active_project_index(void);
// True once this project already has a card, so a caller can skip re-sending one.
bool ui_project_has_event(const char *project_id);
// True when a tile for this project already exists. An UNKNOWN id must not be turned into a tile from an
// event — ask for the authoritative list instead.
bool ui_project_known(const char *project_id);
// True while the project's turn is running. A restored recap must not replace that state.
bool ui_project_is_busy(const char *project_id);
// Clear any "Working…" tile orphaned when its turn.done was lost or never produced. Acts on absence: a
// live turn re-emits every few seconds, so a tile silent for >25s is gone. Call from the ~1s loop.
// Returns how many were cleared.
int ui_prune_stale_busy(void);
// Switch the carousel to a project's tile.
void ui_focus_project(const char *project_id);
// Show/hide the loading spinner over the carousel while the project list is being (re)built.
void ui_set_creating(bool on);

// --- What a turn does to a tile ---
// Append an event as a readable card (keeps the last MAX_EVENTS).
// kind: "processing" | "say" | "act" | "ask" | "done" | "error".
// `recap` (optional, may be NULL) is the short headline shown on the tile at a glance; `text` is the
// fuller body behind the tap-to-read reader. When `recap` is NULL the tile previews `text`.
void ui_project_emit(const char *project_id, const char *kind, const char *text, const char *recap);
// Restore a historical card without touching the live busy lifecycle for this project.
void ui_project_restore_event(const char *project_id, const char *kind, const char *text, const char *recap);
void ui_project_clear_event(const char *project_id);
// A turn finished → wake the screen (if off) and either badge the bell or open the drawer.
void ui_notify_task_done(const char *project_id);

// --- Gestures (touch.c drives all of these) ---
// True when the projects carousel is the active screen.
bool ui_is_projects_active(void);
// True while the full-text reader is open (touch.c gives it a tight, reader-only gesture set).
bool ui_reader_is_open(void);
// Height (px) of the top notification pull-down zone for the CURRENT tile: narrow on a project tile so
// the Model/Effort chips still get taps, full band on Overview. touch.c reads it per press.
int ui_notif_pull_zone_px(void);
void ui_swipe_begin(void);
void ui_swipe_end(int dir);
// Vertical edge-swipe: +1 = up (project → open the reader), -1 = down (reader top → close).
void ui_swipe_vert(int dir);
// A swipe-up that STARTED at the bottom edge → jump to Overview from anywhere.
void ui_home_overview(void);
// A plain tap (when not recording): on the reader → back to the carousel; else no-op.
void ui_tap(uint16_t x, uint16_t y);
// True when a screen-space touch begins on a control that must beat the screen-wide gestures — the
// action bar, and the always-on status-band bell, which sits inside the pull-down zone and would
// otherwise never receive a tap. touch.c consults this before claiming a press.
bool ui_action_hit(uint16_t x, uint16_t y);
// Notification centre: open = pull-down from the top edge; close = swipe-up / tap.
void ui_notif_open(void);
void ui_notif_close(void);
bool ui_notif_is_open(void);
// A swipe-up inside the open drawer → close it, but only if the list is already scrolled to the top.
void ui_notif_swipe_up(void);
// Physical BOOT button. Returns whether the press was CONSUMED: false hands it back so the caller can
// spend it turning the screen off, which is what the common (idle) case should do.
bool ui_boot_pressed(void);

// --- Voice ---
// projectId of the currently-visible tile, or "" from Overview — which is what makes routing the
// transcript a real question rather than a lookup.
const char *ui_get_active_project_id(void);
// Start/stop a voice turn for the visible project. Safe to call from a non-LVGL task.
void ui_voice_start(void);
void ui_voice_start_goal(void);   // Goal pill / long-press → voice.begin carries cmd:"goal"
void ui_voice_start_loop(void);   // Loop pill → voice.begin carries cmd:"loop"
void ui_voice_stop(void);
// is_recording = actively capturing (a tap stops it); is_active = recording OR still waiting on the
// transcript (blocks a new start).
bool ui_voice_is_recording(void);
bool ui_voice_is_active(void);
// grid-app answered a routed (Overview) voice turn. `auto_sent` = it dispatched already, so just focus
// the tile; otherwise the transcript is held and the panel confirms with panel_client_voice_confirm.
// `need_new` = nothing fitted.
void ui_voice_routed(bool auto_sent, bool need_new, const char *route_id, const char *project_id,
                     const char *project_name, double confidence);
// grid-app abandoned a routed voice turn (nothing heard, or transcription failed) → drop the loading
// overlay now instead of waiting out the routing watchdog.
void ui_voice_route_abort(void);

// --- Firmware update ---
// What the screen says while the panel rewrites its own flash. All four run on the connecting screen;
// see the note on the implementation for why there is no progress bar of its own.
void ui_fw_updating(const char *version);
void ui_fw_progress(int pct);
void ui_fw_verifying(void);
void ui_fw_restarting(void);
void ui_fw_failed(const char *message);
// True if ANY project is mid-turn — the one question fw_update asks before accepting an offer.
bool ui_any_project_busy(void);

// Interrupt the running turn of the visible project. No-op if it isn't running. Safe from any task.
void ui_stop_active_turn(void);

// The machine the panel is plugged into, from `welcome`. Drives the Overview eyebrow and the band title.
void ui_set_machine_name(const char *name);

// --- Development instrument ---
// Swipe the whole carousel `passes` times over, so display_draw_stats() has something repeatable to
// measure. Not product behaviour; see the note on the implementation for what it does and does not
// prove. Runs on the CALLER's task and blocks it for ~0.6 s per page.
void ui_scroll_benchmark(int passes);
