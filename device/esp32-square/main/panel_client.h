// The message layer: what the panel and grid-app SAY to each other, on top of the bytes panel_link
// moves. Normative description in docs/protocol.md §2 — that document is written twice, here and in
// lib/infrastructure/panel/panel_message.dart, with no shared code, so it is the only place the two
// halves agree by construction rather than by coincidence.
//
// Two things this layer owns and nothing else does:
//
//   THE HANDSHAKE. The panel says `hello`, the app answers `welcome`, the panel asks for `projects.list`.
//   Until `welcome` lands there is no session and the screen says "Not connected".
//
//   BEING LENIENT. Everything arriving here came off a cable that carries bootloader chatter at every
//   boot and may be talking to a grid-app newer than this firmware. A message that cannot be read is
//   discarded and COUNTED — never a reason to drop the link, and never a reason to reboot.
//
// The vocabulary is grid-app's (docs/overview.md): a `project` is the working unit with a workspace, an
// `agent` is the runtime that answers in it. The reference firmware this device's UI is modelled on uses
// those two words the other way round. Do not copy its labels.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "voice.h"   // voice_cmd_t — the modifier a `voice.begin` carries

// The firmware version reported in `hello` and printed at boot, so a device on someone's desk can be
// identified from its console alone.
//
// READ OUT OF THE RUNNING IMAGE — esp_app_get_description()->version — and never from a constant here.
// That is not tidiness; it is the difference between self-update working and looping forever.
//
// grid-app decides whether to offer an image by comparing this string against the version in the
// esp_app_desc_t of the .bin it carries. Two strings from two sources cannot be kept equal by anyone:
// a macro in this header said "0.1.0" while the image self-described as "v0.3.38-36-gbc640739-dirty"
// (IDF's `git describe` fallback, used when the project sets no PROJECT_VER), so every plug looked like
// a version mismatch and the app would have offered to reflash an identical image, forever.
//
// The version itself is set ONCE, as PROJECT_VER in the top-level CMakeLists.txt, which is what IDF
// stamps into the image description. Bump it there.
//
// Never NULL: esp_app_get_description() reads a structure linked into this very image.
const char *panel_fw_version(void);

// The MESSAGE-layer version. Separate from PANEL_FRAME_VERSION on purpose and bumped for different
// reasons: adding a message is a change here and needs no new reader, changing the envelope is a change
// there and breaks every reader. Conflating them makes the cheap change look as expensive as the
// expensive one.
#define PANEL_PROTO_VERSION 1

// How many projects the panel tracks at once — the size of the UI's tile array (`s_proj` in
// ui_screens.c) and of anything that walks it.
//
// This constant is the reference firmware's, and it lives here for the same reason it lives in that
// firmware's commander_client.h: the layer that receives the list and the layer that renders it must not
// be able to disagree about how many there can be. The UI keeps only a thin shell per project and
// materializes the heavy content for the active tile ± a window, so a hundred costs little more than a
// dozen — a far-off tile holds ZERO LVGL objects.
#define MAX_PROJECTS 100

// projectId + nul. grid-app's ids are uuids; the reference's were uuids or 32-hex. Same 48.
#define ID_MAX 48

// Start the link and the handshake. Returns false only if the USB link itself would not come up, which
// leaves the panel running and showing "Not connected" rather than failing to boot.
//
// Call AFTER ui_init(): the first thing this does is push a link state into the UI.
bool panel_client_start(void);

// Send what the user asked for on the panel, into `project_id`.
//
// grid-app decides which conversation inside that project the words go into, and it is the only thing
// that could — the panel never sees a conversation. Fire-and-forget: everything after this arrives back
// as `turn.started` / `turn.parts` / `turn.done`, or as `turn.error` in words a person can act on.
void panel_client_send_turn(const char *project_id, const char *text);

// Ask grid-app to interrupt this project's turn.
//
// The id travels because the panel can stop a project the desktop does not have open (protocol.md §2).
// Safe to call from the LVGL task — display_lock() is recursive — but it does a USB write, which blocks
// for up to the link's write timeout when the host is not draining the port.
void panel_client_stop_project(const char *project_id);

// The firmware-image payload kind, docs/protocol.md §1: "one slice of a firmware image, app → device
// only".
//
// It lives HERE and not beside PANEL_TYPE_JSON / PANEL_TYPE_PCM in panel_frame.h, which is where it
// belongs, for one reason: panel_frame.{c,h} is the codec that also compiles with a plain host compiler
// against the shared vectors (scripts/test_frame.sh), and this change does not touch it. ⚠️ TODO(BE):
// fold it back into panel_frame.h next time that file is opened, so the three payload kinds are listed
// in one place.
#define PANEL_TYPE_FW 0x03

// Whether `welcome` has been seen and the session is still believed to be live.
bool panel_client_is_connected(void);

// ── WHAT THE OTHER HALVES SAY ───────────────────────────────────────────────────────────────────────
// Message CONSTRUCTION stays in panel_client.c even for messages whose logic lives elsewhere: voice.c
// owns the microphone and fw_update.c owns the flash, but the vocabulary — every `t` this panel emits —
// is one file's business, because it is the half of docs/protocol.md this device is responsible for.
// A message built in three files is a vocabulary that drifts in three directions.

// A voice turn. `project_id` may be "" or NULL, in which case `voice.begin` OMITS the field entirely
// rather than sending an empty one — protocol.md §2 makes the key optional and absence is what tells
// grid-app it has to route the transcript itself.
void panel_client_voice_begin(const char *project_id, voice_cmd_t cmd);

// One PCM chunk as a 0x02 frame. Returns false when the host is not reading, which ends the turn.
bool panel_client_send_pcm(const uint8_t *pcm, size_t len);

void panel_client_voice_end(void);

// Answer a `voice.transcript` that arrived with `needsConfirm`.
void panel_client_voice_confirm(const char *route_id, const char *project_id);

// The firmware-update side of the conversation. Declining an offer is NOT one of these: protocol.md §2
// says declining is simply not answering, and the app offers again on the next `hello`.
void panel_client_fw_accept(void);
void panel_client_fw_progress(uint32_t written);

// ── SCREENSHOTS (development instrument) ────────────────────────────────────────────────────────────
// Three messages the panel emits while ui_screenshot.c walks the frame buffer. Not part of the product
// vocabulary: protocol.md §2 requires a peer to ignore what it does not know, so grid-app counts these
// as PanelUnknown and carries on. See ui_screenshot.c for the format and why it is not on the console.
void panel_client_shot_begin(const char *name, int w, int h);
void panel_client_shot_row(int y, const char *b64);
void panel_client_shot_end(const char *name);
void panel_client_fw_done(void);
void panel_client_fw_error(const char *message);

// Message-layer health, alongside panel_link_counters()'s framing health.
//
// `bad` counts payloads that were not readable JSON or carried no `t`; `unknown` counts well-formed
// messages this build has no case for, plus frames whose payload TYPE this build does not know. They are
// separate because they mean opposite things: `bad` is corruption or a bug, `unknown` is a grid-app
// running ahead of this firmware — a version mismatch someone can act on rather than a fault.
void panel_client_counters(uint32_t *bad, uint32_t *unknown);
