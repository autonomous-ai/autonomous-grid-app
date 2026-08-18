// The device's own preferences, in NVS.
//
// What is NOT here is the point. The reference carried a `config_store` holding WiFi credentials, a
// pairing token, a passcode, an E2EE keypair and a provisioning state machine — every one of which
// this firmware cut, because the cable is the authorization and grid-app owns the rest. What is left
// is what the DEVICE decides and nobody else can: how bright its own screen is, and which language the
// person holding it speaks.
//
// Kept as its own file rather than folded into ui_screens.c so the NVS namespace has one owner. A
// second writer of the same namespace is how two settings end up disagreeing about what is stored.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Bring up NVS. Called once from app_main before anything reads a preference. Tolerates a flash
// partition that has to be erased first (a version bump, or a first boot after a layout change) —
// losing a brightness level is not worth failing to start over.
void device_prefs_init(void);

// Screen brightness (the level `ui_set_brightness` takes, 0x00–0xFF). ~60% when nothing is stored.
uint8_t device_prefs_brightness(void);

// Remember [level]. Called on the release of a drag, never during one: NVS is flash, and a write per
// pointer-move would spend erase cycles on a value the user is still choosing.
void device_prefs_set_brightness(uint8_t level);

// The language voice capture is transcribed in — "en" or "vi", written into `out`.
//
// The DEVICE owns this once someone has touched it. grid-app proposes a starting value from the
// machine's own locale (`welcome.voiceLang`), which is the right default and a poor decision: the
// person holding the panel may well speak something else than the laptop is set to. So the app's value
// seeds this, a tap on the Settings row overrides it, and the override is what rides every capture.
//
// Returns false when nothing has been stored yet — which is what makes "seed from the app" and "the
// user has chosen" tellable apart. Without that distinction every `welcome` would undo the tap.
bool device_prefs_voice_lang(char *out, size_t cap);
void device_prefs_set_voice_lang(const char *lang);

// ── The screen lock ─────────────────────────────────────────────────────────────────────────────────
// A 3x3 pattern. Only a SALTED SHA-256 of the dot sequence is stored — the pattern itself never is, so a
// dump of NVS does not hand someone the shape.
//
// Casual security, and worth saying plainly: a smudge trail on the AMOLED or one glance over a shoulder
// leaks the pattern. It stops a passer-by poking someone's agents. It does not stop anyone holding the
// cable, and it was never going to — over that cable this firmware can be replaced wholesale.
bool device_prefs_lock_enabled(void);
void device_prefs_set_lock(const char *pattern);
bool device_prefs_check_lock(const char *pattern);
void device_prefs_clear_lock(void);
