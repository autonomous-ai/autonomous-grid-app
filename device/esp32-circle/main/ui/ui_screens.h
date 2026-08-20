// LVGL screens for the Grid panel (round 466x466). Thread-safe: each function takes the LVGL lock
// internally (display_lock/unlock), so the USB link task may call them directly.
//
// This is the reference firmware's ui_screens.h with the screens this device has no question for
// deleted. What went, and why the question cannot arise here:
//
//   provisioning / setup chooser / pairing / E2EE  — there is no radio and no account. The cable is the
//                                                    authorization (docs/panel-protocol.md §4).
//   the WiFi picker, the no-WiFi retry state       — same.
//   Settings, and the gear that was its only door  — brightness, voice language, reset and passcode all
//                                                    stored to a config_store this firmware does not have.
//   the Machines wheel                             — this panel sees ONE machine: the computer holding
//                                                    the cable.
//   the 3x3 pattern lock                           — it hashed into config_store, and physical access to
//                                                    the cable already grants everything it guarded.
//   the Model/Effort picker                        — its models_list RPC has no counterpart in grid-app.
//                                                    The chips stay, display-only.
//   the voice quota                                — a daily allowance the backend enforced.
//   the OTA boot-mode screen                       — that OTA downloaded over HTTP. Cable transfer
//                                                    (fw_update.c) draws its progress on the normal screen.
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>   // size_t (ui_tile_id_at)

struct cJSON;

void ui_init(void);

// Set screen brightness (0x00 dimmest .. 0xFF max) — a software dim overlay. Kept without its slider:
// display.c's sleep/wake path is the only caller now, and a panel that cannot dim is a panel that burns
// an AMOLED at a desk.
void ui_set_brightness(uint8_t level);

// PROPOSE the language voice capture is transcribed in ("en" / "vi") — grid-app's reading of the
// machine's own locale, sent on `welcome`.
//
// Ignored once the Settings page's Voice row has been tapped: that choice is in NVS and wins. Without
// that, the 15s keepalive `welcome` would undo the tap every time and the row would look like a switch
// that springs back. Safe to call on every welcome; it refreshes the label in place rather than
// rebuilding the list, which would reset its scroll under a reader's finger.
void ui_set_voice_lang(const char *lang);

// ── The screen lock ─────────────────────────────────────────────────────────────────────────────────
// Wire the sleep/wake gate and, on a genuine power-on, demand the pattern before anything else. Called
// once from ui_init. A no-op when no passcode is set.
void ui_lock_init_gate(void);

// Settings → Passcode: set a pattern when there is none, or ask for the current one to turn it off.
void ui_lock_setup(void);

// Whether the unlock overlay is up. The gesture layer asks so a swipe under it cannot move the carousel.
bool ui_lock_active(void);

// The language to transcribe in — what `voice.begin` carries. Never empty: "vi" when nothing has been
// stored or proposed, which is the server's own default too.
const char *ui_voice_lang(void);

// --- Full-screen states ---
// The one error screen that survived. Used for a protocol-version mismatch and for `voice.error`, both of
// which are states a person can act on rather than faults to swallow.
void ui_show_error(const char *title, const char *detail);
// A message that says itself and then gets out of the way (6 s, then back to the carousel). ui_show_error
// loads a screen and STAYS there, which is right for a version mismatch and wrong for a voice press that
// caught no speech: the panel would be stuck on a notice about something that already finished.
void ui_show_notice(const char *title, const char *body);
// If the error screen is currently shown, return to the projects view (used when a session re-establishes,
// so a transient error does not leave the device stuck on a stale one).
void ui_leave_error_screen(void);

// --- Projects carousel (swipe left/right between the Overview and the projects) ---
// The ring is Overview -> project 0 -> ... -> project N -> (wraps). No Settings tile, no Machines tile.
void ui_show_tiles(void);
// Boot landing: park on the Overview tile with a spinner instead of the "No projects" empty page. The
// projects have not loaded yet — grid-app has not even said welcome — and flashing an empty state at boot
// says something false about a computer that may have a dozen.
void ui_enter_boot_loading(void);
// The list arrived: drop the spinner and land on a project (or stay on the Overview when empty).
void ui_land_after_reload(void);
// grid-app has gone quiet for longer than the heartbeat allows (docs/panel-protocol.md, "Heartbeat"):
// clear the stale project model and turn the Overview into the "the app is turned off" guide. The link
// layer keeps saying `hello`; ui_leave_remote_offline_loading() switches the guide back to the spinner
// when someone answers.
void ui_enter_remote_offline(void);
void ui_leave_remote_offline_loading(void);
// Whether a `welcome` has been seen — drives the tile dots and the action row's enabled state.
void ui_set_connected(bool connected);
// The machine's display name, from `welcome.machine.name`. Drawn as the Overview's eyebrow.
void ui_set_machine_name(const char *name);

// Ensure a tile exists for chat_id (creates one if new) and set the human name shown on it. THIS is
// what creates a tile, so it must be called before the three setters below.
void ui_tile_set_project(const char *chat_id, const char *project);
void ui_tile_set_name(const char *chat_id, const char *name);
// The engine mark drawn on the chip row: claude | codex | hermes | pi. An id this build has no mark for
// draws no mark rather than a placeholder — the row still reads (docs/panel-protocol.md, project shape).
void ui_tile_set_engine(const char *chat_id, const char *engine);
// The model chip's text. Display-only: nothing on this device can change a model, so a tap does nothing.
void ui_tile_set_selected_model(const char *chat_id, const char *model);

// Remove a project's tile. No-op if the id isn't shown.
void ui_tile_remove(const char *chat_id);
// Copy the id of the project tile at index i into buf; false if out of range (used to reconcile removals).
bool ui_tile_id_at(int i, char *buf, size_t n);
// Number of project tiles currently shown.
int ui_tile_count(void);
// True once this project already has a recap card, so a `projects` list does not overwrite something
// fuller that a finished turn already put there.
bool ui_tile_has_event(const char *chat_id);
// True while ANY project's turn is running — fw_update.c's "never mid-turn" guard.
bool ui_any_tile_busy(void);
// Clear any "Working…" tile orphaned when its turn.done was lost or never produced. Acts on ABSENCE:
// nothing has stamped that project for >25s. A live turn keeps stamping (turn.parts) and is never cut
// short. Call from the ~1s loop. Returns #cleared.
int ui_prune_stale_busy(void);
// True while the full-text detail reader is active (touch.c gives it a tight, reader-only gesture set).
bool ui_reader_is_open(void);
// Height (px) of the top notification pull-down zone for the CURRENT tile: narrow (44) on a project tile
// so the chip row still gets taps, full band (90) on the Overview. touch.c reads it per press.
int ui_notif_pull_zone_px(void);
// Circular swipe, driven by touch.c.
void ui_swipe_begin(void);
void ui_swipe_end(int dir);
// Vertical edge-swipe: +1 = up (project → open the detail reader), -1 = down (reader top → close).
// "Home" gesture: a swipe-up that STARTED at the bottom edge → jump to the Overview tile from anywhere.
void ui_home_overview(void);
// Voice-state queries for the gesture layer: is_recording = actively capturing (a tap stops it);
// is_active = recording OR the clip still uploading (blocks a new start).
bool ui_voice_is_recording(void);
bool ui_voice_is_active(void);
// True when a screen-space touch begins on one of the visible action buttons — the Overview's three pills
// or an agent tile's three marks. touch.c uses this to give that button the whole gesture, so a press
// cannot also register as the tap that opens the detail reader.
bool ui_action_row_hit(uint16_t x, uint16_t y);
// A plain tap (touch.c, when not recording): on the detail reader → back to projects; else no-op.
void ui_tap(void);
// Notification centre (touch.c drives open/close).
void ui_notif_open(void);
void ui_notif_close(void);
bool ui_notif_is_open(void);
void ui_notif_swipe_up(void);
// Show/hide the boot loading indicator.
void ui_set_creating(bool on);

// Switch the carousel to a project's tile.
void ui_focus_tile_from_app(const char *chat_id);
void ui_focus_tile(const char *chat_id);
// Drop every project tile (the app went away and its list is now a claim about a machine that is gone).
// Put the tiles in this order — the app's list order, which is the order its sidebar shows. Called at the
// end of the reconcile, once every add and removal has landed.
//
// The id width is spelled out because ID_MAX lives in panel_client.h and these two headers do not include
// each other; the call site asserts the two agree.
void ui_tiles_reorder(const char ids[][48], int n);
void ui_tile_clear_all(void);

// Voice router result, from `voice.transcript`. `auto_sent` = grid-app already dispatched (just focus the
// tile); otherwise `needsConfirm` was set, the transcript is held, and confirming sends `voice.confirm`.
// `need_new` = the app named no project. Runs on the link task (takes the display lock).
void ui_voice_routed(bool auto_sent, bool need_new, const char *route_id, const char *chat_id,
                     const char *transcript);
// grid-app abandoned a routed voice turn (`voice.error`) → drop the loading overlay now instead of
// waiting out the routing watchdog. No-op unless a route voice is waiting.
void ui_voice_release(void);
void ui_voice_route_abort(void);
// A turn finished for this project → wake the screen (if off) and jump to that project's tile.
void ui_notify_task_done(const char *chat_id);

// --- The turn, as the panel draws it ---
// One lifecycle event for a project's tile.
//   kind: "processing" (a turn is running — also the heartbeat ui_prune_stale_busy measures)
//         "done" | "error"  (the turn ended; `text` is the recap)
//   `recap` (optional, may be NULL): a short headline shown on the tile; `text` is the fuller body the
//   detail reader shows. When `recap` is NULL the tile previews `text`.
void ui_tile_emit(const char *chat_id, const char *kind, const char *text, const char *recap);
// Restore a historical recap without touching the live turn lifecycle (a `projects` list arriving while
// a turn is running must not clear the Working row).
void ui_tile_restore_event(const char *chat_id, const char *kind, const char *text, const char *recap);
// The recap card's tint, from `recapKind`: done | failed | stopped. An unrecognised value is drawn as
// `done`, NEVER as an error — guessing "failed" on a turn that worked is the worse of the two mistakes.
void ui_tile_set_recap_kind(const char *chat_id, const char *recap_kind);
// The long form of the last recap, from the `summary` message. Overwrites rather than appends: it is
// keyed by chatId and describes the last COMPLETED turn. May never arrive.
void ui_tile_set_summary(const char *chat_id, const char *text);
// Anchor the elapsed clock. `turn.started` is when the device starts counting; every step's `t0` is
// milliseconds from THIS moment (docs/panel-protocol.md, `turn.parts`). The device must not timestamp a
// step when it first sees it — onAttach re-sends the whole timeline after a reboot and every step would
// read as having just begun.
void ui_tile_turn_started(const char *chat_id);

// The live "current step" block above the Working row. Two lines, overwritten each call:
//   line 1 = `tool` (coloured by `kind`, never inferred from the tool's NAME) + `label` (muted)
//   line 2 = `arg` (muted raw argument — the command/query/url; NULL/empty hides it, wraps to three
//            lines then ellipsis)
// `kind` is one of command | web | tool | thinking. Cleared when the turn ends.
void ui_tile_set_tool(const char *chat_id, const char *tool_name, const char *label,
                         const char *kind, const char *detail);

// The sub-agent band: the steps of `turn.parts` that carry a `parent`. `rows` is a cJSON array of
// {text, color} the caller has already composed — the wire carries no sub-agent TYPE, so the name is a
// randomised gerund and the elapsed comes from the step's `t0`. NULL/empty clears it.
void ui_tile_set_agents(const char *chat_id, const struct cJSON *rows);

// The plan, from `turn.parts.todos[]`: an array of {c, s} where `s` uses the step vocabulary
// (running | done | failed | unknown). ABSENT means the agent has no plan, which is different from an
// empty plan and is drawn as nothing at all. Windows to 4 rows centred on the running task.
void ui_tile_set_todos(const char *chat_id, const struct cJSON *todos);

// --- Questions (the `question` message) ---
// Show the card: a summary, an optional command, and the app's own option list. `options` is the cJSON
// array of {id, label} — the device must NOT invent an option and must NOT assume there are two.
// `id` is opaque and is echoed back verbatim in `answer`.
void ui_question_show(const char *chat_id, const char *id, const char *summary,
                      const char *command, const struct cJSON *options);
// `question.cancel` — clear the card if it is this one. Arrives at any moment and WILL: the desktop shows
// the same question and whichever surface answers first cancels the other.
void ui_question_cancel(const char *chat_id, const char *id);
// True while a question card is up (voice is refused then; a question is answered by tapping).
bool ui_awaiting_answer(void);

// --- Voice ---
// The project id of the currently-visible tile, or "" on the Overview.
const char *ui_active_tile_id(void);
// Start a plain capture for the visible tile — the double-tap gesture's way in (touch.c). The buttons on
// the Overview and on an agent tile do not come through here: they name the command they mean (Goal, Loop)
// and call it directly.
void ui_voice_start(void);
// Stop the running capture. Safe to call from a non-LVGL task.
void ui_voice_stop(void);

// Ask grid-app to interrupt the visible project's turn. No-op if that tile isn't working.
void ui_stop_active_turn(void);
// Physical BOOT button. Routes to "back" (dismiss the question) while a question is on screen, otherwise
// to ui_stop_active_turn(). Safe from a non-LVGL task.
void ui_boot_pressed(void);

// --- Firmware update over the cable (fw_update.c drives these) ---
void ui_fw_updating(const char *version);
void ui_fw_progress(int pct);
void ui_fw_verifying(void);
void ui_fw_restarting(void);
void ui_fw_failed(const char *message);

// --- Development instruments (not product code) ---
// Swipe the carousel end to end `passes` times, so a stutter can be MEASURED instead of described. A
// finger cannot: swipe speed and length vary per try, which is the variance that makes "is it smoother
// now?" unanswerable. Driven from a `scrolltest` message, which grid-app ignores as unknown.
void ui_scroll_benchmark(int passes);
