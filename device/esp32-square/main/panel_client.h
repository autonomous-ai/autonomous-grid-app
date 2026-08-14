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
#include <stdint.h>

// The firmware version reported in `hello` and printed at boot, so a device on someone's desk can be
// identified from its console alone.
#define PANEL_FW_VERSION "0.1.0"

// The MESSAGE-layer version. Separate from PANEL_FRAME_VERSION on purpose and bumped for different
// reasons: adding a message is a change here and needs no new reader, changing the envelope is a change
// there and breaks every reader. Conflating them makes the cheap change look as expensive as the
// expensive one.
#define PANEL_PROTO_VERSION 1

// Start the link and the handshake. Returns false only if the USB link itself would not come up, which
// leaves the panel running and showing "Not connected" rather than failing to boot.
//
// Call AFTER ui_screens_init(): the first thing this does is push a link state into the UI.
bool panel_client_start(void);

// Ask grid-app to interrupt this project's turn.
//
// The id travels because the panel can stop a project the desktop does not have open (protocol.md §2).
// Safe to call from the LVGL task — display_lock() is recursive — but it does a USB write, which blocks
// for up to the link's write timeout when the host is not draining the port.
void panel_client_stop_project(const char *project_id);

// Whether `welcome` has been seen and the session is still believed to be live.
bool panel_client_is_connected(void);

// Message-layer health, alongside panel_link_counters()'s framing health.
//
// `bad` counts payloads that were not readable JSON or carried no `t`; `unknown` counts well-formed
// messages this build has no case for, plus frames whose payload TYPE this build does not know. They are
// separate because they mean opposite things: `bad` is corruption or a bug, `unknown` is a grid-app
// running ahead of this firmware — a version mismatch someone can act on rather than a fault.
void panel_client_counters(uint32_t *bad, uint32_t *unknown);
