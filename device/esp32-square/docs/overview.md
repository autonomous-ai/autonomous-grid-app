# Grid Panel — overview

A 480×480 touch panel that sits on the desk, plugged into a computer over USB, and drives that
computer's **grid-app**: one tile per project, live turn state, an interrupt button, and a voice
button.

This document says what the thing is, why it is built the way it is, and where the boundary between
the two halves runs. For the byte-level contract see [`protocol.md`](protocol.md); for the board
itself see [`hardware.md`](hardware.md).

---

## Where this came from

There is an existing device in another repo — `autonomous-code/apps/esp32-square-s3` — that does
almost exactly this, for a different product (Harness: agents in cloud containers). It runs on the
same board.

**That firmware is a reference, not a dependency.** Nothing here links against it, imports from it,
or speaks its protocol. What is borrowed is the *shape*: the screen layout, the boot-flow state
machine, the hardware bring-up, and a fair amount of hard-won knowledge about this board that is
written down nowhere else.

Why not just point that firmware at grid-app? Two reasons, and the second is the real one:

1. Its wire vocabulary is Harness's, where **`agent`** is the working unit with a workspace and
   **`engine`** is the runtime. grid-app uses those words the other way round — an `agent` *is* the
   runtime, and the working unit is a `project`. Adopting its protocol buys a translation layer
   that never goes away and that every future reader has to hold in their head.
2. Its protocol is already maintained in three copies across three boards, with a drift-checking
   script holding them together. Becoming the fourth speaker — in a different language, in a
   different repo — extends a problem rather than solving one.

So: own protocol, own vocabulary, own repo. The reference stays useful as something to read.

---

## Why USB, and what that bought

The device is always plugged into the computer anyway. Given that, the network was never needed.

**Bandwidth was never the question.** The heaviest thing on this link is voice, and the capture is
16 kHz mono 16-bit — **32 KB/s**. The board's native USB does hundreds of KB/s. Even reflashing the
whole firmware (2.46 MB) is a matter of seconds. There is more than an order of magnitude of slack.

The question was what dropping the network *removes*, and the answer is roughly a third of the
project:

| Gone | Why it existed |
|---|---|
| WiFi provisioning | SoftAP portal, saved-network list, picker, cool standby, roaming reboot |
| Pairing | mDNS, a confirmation code, token issue, a token store per machine |
| A LAN server in grid-app | …and with it the largest attack surface in the design |
| OTA over the internet | public bucket, manifest, SHA verify, rollback, an upload pipeline |
| Reconnect ladder | 5s heal, 15s reboot — and the ugly trade where a backend outage reboot-cycles the device |

It also collapses the security model to something that needs no code: **plugging the cable in is
the authorization.** Whoever did it was standing in front of the machine.

And it removes version skew as a category. Firmware and app ship from one repo, so the app can
carry the `.bin` and reflash a panel that is behind — over the same cable it is already talking on.
The two cannot drift.

### What it costs

The panel only sees the computer it is plugged into, and it goes dark when that computer sleeps.
The intended answer is that the **host proxies**: the machine holding the cable is itself one
machine and also the way to reach other grid-app instances on the network. The panel stays simple
and knows about exactly one peer; the fleet logic lives in Dart, where it is much easier to write
than in C on a microcontroller.

That part is designed, not built.

---

## The two halves

```
┌── device/esp32-square ─────────┐        ┌── grid-app (Flutter, desktop) ──────────┐
│  UI (LVGL) — tiles, settings   │        │  panel service — projects, turn events, │
│  message layer                 │◄─USB──►│  stop, voice                            │
│  framing                       │  CDC   │  message layer  ·  framing              │
│  board · NVS                   │        │  ↓ reuses the app's own controllers      │
└────────────────────────────────┘        └──────────────────────────────────────────┘
                                                    │              │
                                            agent runtimes    grid relay (models)
                                                    │
                                              cloud STT (audio only, from the desktop)
```

**Four rules the design rests on.**

1. **The panel runs nothing.** It calls no model, runs no agent, opens no file. Everything real
   happens in grid-app; the panel is the glass.
2. **The panel holds no cloud credential.** The STT key lives on the desktop, in the app's existing
   key store. Losing the panel loses nothing.
3. **The service reads through the app's own controllers**, never straight off disk. grid-app has a
   written invariant that `~/.grid` is the single source of truth and that the app runs a command
   and then *re-reads the disk*. A second reader would give you two truths that disagree, and the
   symptom is "the panel says one thing and the window says another" — a miserable bug to chase.
4. **The message layer does not know it is on USB.** Framing is the layer below and is replaceable.

---

## Vocabulary

Fixed once, in grid-app's words, because the app is the side with the larger vocabulary and the
more readers:

| Concept | Word | Not |
|---|---|---|
| The working unit with a workspace | **project** | agent |
| The runtime that answers in it (Claude Code, Codex, Hermes, Pi) | **agent** | engine |
| One conversation | **conversation** | session |
| The computer a panel is plugged into | **machine** | node, host |

The reference firmware's screens say "agent" where these say "project". The layout is copied; the
labels are not.

---

## Status and order of work

Built and tested: the framing codec on both sides, the message layer in Dart, and a manual probe
that drives a real device with no Flutter, no Xcode and no app build.

Built but not yet seen working end to end: the firmware's message layer (`main/panel_client.c`) and
the tile screens (`main/ui/ui_screens.c`) — handshake, project tiles, turn events and Stop. They
compile and the board runs the build; what nobody has watched yet is a real grid-app on the other
end of the cable, and the touch orientation the carousel swipe depends on is still unverified
(`hardware.md`).

Not built: the grid-app service, and voice.

The intended order, and the reasoning for it:

1. **Framing** — blocks both sides, so it goes first, and both sides get stubs immediately after.
2. **Plug in and see projects** — the first visible milestone. Read-only, so it cannot break
   anything.
3. **Turn events** — type on the desktop, the tile lights up. Still read-only, and already useful.
4. **Interrupt** — the first write path, and the smallest.
5. **Self-flash** — deliberately before voice: from here on, changing the protocol no longer means
   plugging in a flashing cable by hand, so every later loop is cheaper.
6. **Voice** — the largest piece, standing on something that already works.
7. **Proxy to other machines** — pure Dart.

One known gap in grid-app that step 4 runs into: its `stop()` only stops the chat the desktop
currently has open, and there is no public per-conversation stop. The panel needs to interrupt any
project, so that method has to be added. It is small, and it is useful to the app regardless.
