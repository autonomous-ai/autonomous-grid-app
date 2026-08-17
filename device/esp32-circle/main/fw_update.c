#include "fw_update.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "display.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "panel_client.h"
// For PANEL_MAX_PAYLOAD — the ack cadence is one slice, and a slice is one frame's payload.
#include "panel_frame.h"
#include "ui_screens.h"
#include "voice.h"

// ── A guard on the one config this file cannot do without ───────────────────────────────────────────
// Everything else about a bad update is recoverable over the same cable it arrived on. The one
// unrecoverable class is an image that does not boot: this panel has no network, no recovery mode and no
// second channel, so a device that will not run its new firmware needs a person, a cable and esptool.
// Rollback is what makes that impossible — the bootloader reverts an image that never confirms itself.
//
// The reference firmware asserts its own OTA invariants at compile time for a reason it paid for:
// sdkconfig is generated and gitignored while sdkconfig.defaults only seeds a MISSING one, so a machine
// that has been building since before a defaults change silently keeps the old values. This project
// stamps the defaults' hash to force a re-seed (see the top-level CMakeLists.txt), which should make
// that impossible — but "should" is exactly what the reference believed too, and this check is free.
#if !defined(CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE)
#error "Self-update safety: CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE must be set, or an image that does not \
boot is permanent and every unit needs a USB flash by hand. It is in sdkconfig.defaults; regenerate with \
rm device/esp32-circle/sdkconfig && idf.py reconfigure"
#endif

static const char *TAG = "fw";

// ── WHICH TASK RUNS WHAT ────────────────────────────────────────────────────────────────────────────
// The offer, every slice, the verify and the reboot all run on the LINK's reader task, one after
// another — which is also this transfer's entire flow control: nothing is read off the USB port while a
// slice is being written to flash, so the host cannot outrun the writer.
//
// Two entry points come from elsewhere: fw_abort() from whichever task noticed the session end, and
// fw_tick() from the handshake task. Both can in principle land between two writes, and neither is
// locked against them. That is deliberate rather than overlooked: the worst outcome of the race is an
// esp_ota_abort() beside an esp_ota_write() and an update given up on. esp_ota_set_boot_partition() is
// reached from ONE place, at the end of the one task that does the writing, so no interleaving can
// leave this panel booting an image that was not verified.

// How often `fw.progress` goes out.
//
// Every slice, because this message is not only a progress bar — it is the ACK that opens the app's
// credit window (docs/panel-protocol.md, "Firmware update"). Acking rarely means the app is allowed to have
// more bytes in flight than the RX ring can hold while this task sits inside esp_ota_write(), and this
// peripheral drops what it cannot buffer without telling either side (see panel_link.c).
//
// It was 64 KB, and that is precisely why the first real transfer wrote nothing at all: the app pushed
// its whole window before the first ack was due, and almost none of it survived. ~164 small JSON
// messages across a 1.3 MB image is a rounding error against the image itself.
#define PROGRESS_EVERY PANEL_MAX_PAYLOAD

// The read-back buffer for the verification pass. Internal RAM and small: it is read one chunk at a time
// straight into a SHA-256, so there is nothing to be gained by making it big.
#define READBACK_CHUNK 4096

// Yield to the scheduler this often during the read-back. The verify runs on the link's reader task and
// nothing else is happening on the cable at that point, but the task watchdog watches the idle tasks
// (5 s here) and a tight 2.5 MB loop over flash would starve them into a warning that has nothing to do
// with the actual problem.
#define READBACK_YIELD_EVERY 16

// How long a transfer may go without a slice before it is abandoned. Generous, because the panel's own
// flash writes are what pace it and a busy desktop can be slow to answer — and because giving up on an
// update that was going to finish costs the whole download again.
#define STALL_GIVE_UP_US (30 * 1000000LL)

static const esp_partition_t *s_part;
static esp_ota_handle_t       s_handle;
static bool                   s_busy;
static int                    s_size;
static int                    s_written;
static int                    s_next_report;
static int                    s_last_pct;
static char                   s_version[48];
static char                   s_sha[72];
static int64_t                s_last_slice_us;

static void fail(const char *message)
{
    if (s_handle) { esp_ota_abort(s_handle); s_handle = 0; }
    s_busy = false;
    s_part = NULL;
    // The old image is still the boot image: esp_ota_set_boot_partition is the LAST thing this file does
    // and only on the success path, so every failure here costs the download and nothing else. That is
    // what the second OTA slot in partitions.csv is for.
    ESP_LOGE(TAG, "update failed — staying on %s: %s", s_version[0] ? s_version : "the current image", message);
    panel_client_fw_error(message);
    display_lock();
    ui_fw_failed(message);
    display_unlock();
}

// SHA-256 the bytes that are ACTUALLY IN THE PARTITION and compare to what the offer promised.
//
// Not the bytes that arrived — those were already hashed by the CRC on every frame, and a transfer that
// checksummed clean can still land wrong: a write that silently short-changed a sector, a slot that was
// not erased where it was meant to be. This is the check that covers the flash, and it is the one
// docs/panel-protocol.md asks for ("the device verifies sha256 over what it actually wrote").
//
// Runs AFTER esp_ota_end, which is also when it becomes correct to run: esp_ota_write holds back the
// last sub-16-byte remainder of the image and only flushes it in esp_ota_end, so a read-back before that
// would be missing up to fifteen bytes and would fail for a reason that has nothing to do with the data.
static bool written_hash_matches(void)
{
    uint8_t *buf = heap_caps_malloc(READBACK_CHUNK, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (!buf) { ESP_LOGE(TAG, "no RAM to read the image back"); return false; }

    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    bool ok = mbedtls_sha256_starts(&ctx, 0) == 0;
    for (int off = 0, turns = 0; ok && off < s_size; turns++) {
        int n = s_size - off;
        if (n > READBACK_CHUNK) n = READBACK_CHUNK;
        if (esp_partition_read(s_part, off, buf, (size_t)n) != ESP_OK) {
            ESP_LOGE(TAG, "read-back failed at %d/%d", off, s_size);
            ok = false;
            break;
        }
        ok = mbedtls_sha256_update(&ctx, buf, (size_t)n) == 0;
        off += n;
        if (turns % READBACK_YIELD_EVERY == 0) vTaskDelay(1);
    }
    uint8_t digest[32];
    if (ok) ok = mbedtls_sha256_finish(&ctx, digest) == 0;
    mbedtls_sha256_free(&ctx);
    free(buf);
    if (!ok) return false;

    char hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (strcasecmp(hex, s_sha) != 0) {
        ESP_LOGE(TAG, "sha256 of the written image is %s, the offer said %s", hex, s_sha);
        return false;
    }
    return true;
}

static void finish(void)
{
    // esp_ota_end flushes the held-back tail and validates the image's own magic and checksum. It is a
    // different check from the SHA below and both are worth having: this one says "this is a bootable
    // ESP32 image", the SHA says "this is the image grid-app meant to send".
    esp_err_t e = esp_ota_end(s_handle);
    s_handle = 0;
    if (e != ESP_OK) { fail("The panel could not finish writing the update."); return; }

    display_lock();
    ui_fw_verifying();
    display_unlock();

    if (!written_hash_matches()) { fail("The update did not arrive intact."); return; }

    e = esp_ota_set_boot_partition(s_part);
    if (e != ESP_OK) { fail("The panel could not switch to the new firmware."); return; }

    s_busy = false;
    ESP_LOGW(TAG, "firmware %s installed and verified — restarting", s_version);
    panel_client_fw_done();
    display_lock();
    ui_fw_restarting();
    display_unlock();
    // Long enough for the frame to leave the port and the screen to repaint, short enough that it reads
    // as a restart rather than a hang. The reboot is unconditional: the new image is the boot image now,
    // and continuing to run the old one would leave the panel reporting a version it is no longer going
    // to be.
    vTaskDelay(pdMS_TO_TICKS(400));
    esp_restart();
}

void fw_mark_valid(void)
{
    const esp_partition_t *run = esp_ota_get_running_partition();
    esp_ota_img_states_t st;
    if (!run || esp_ota_get_state_partition(run, &st) != ESP_OK) return;
    if (st != ESP_OTA_IMG_PENDING_VERIFY) return;

    // WHAT COUNTS AS "IT RUNS" — and this is a judgement, not a formality.
    //
    // The caller confirms after the display is up and the USB driver is installed, which is everything
    // that has to work for the panel to be fixable again: it can draw, and grid-app can reach it to
    // offer another image. Waiting for something further out — a `welcome`, say — would roll a perfectly
    // good image back because someone unplugged the cable, and an unplugged cable is this device's
    // resting state rather than a fault.
    esp_ota_mark_app_valid_cancel_rollback();
    const esp_app_desc_t *me = esp_app_get_description();
    ESP_LOGW(TAG, "new firmware confirmed (%s) — rollback cancelled", me ? me->version : "?");
}

void fw_on_offer(const char *version, int size, const char *sha256)
{
    if (s_busy) {
        ESP_LOGW(TAG, "already installing — ignoring an offer of %s", version ? version : "?");
        return;
    }

    // ── Is this offer usable at all? ────────────────────────────────────────────────────────────────
    // Answered before the "is now a good time" question, because these are not declines: an offer with
    // no size or a half-length hash is a bug on the app side, and staying silent about it would leave
    // the app re-offering the same broken thing at every hello with nothing to go on.
    if (!version || !version[0] || size <= 0 || !sha256 || strlen(sha256) != 64) {
        panel_client_fw_error("The update offer was incomplete (needs a version, a size and a sha256).");
        return;
    }
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (!part) { panel_client_fw_error("The panel has no free firmware slot."); return; }
    if ((size_t)size > part->size) {
        char msg[96];
        snprintf(msg, sizeof(msg), "The update is %d KB and the panel's slot holds %u KB.",
                 size / 1024, (unsigned)(part->size / 1024));
        panel_client_fw_error(msg);
        return;
    }

    // ── NEVER MID-TURN ──────────────────────────────────────────────────────────────────────────────
    // An update that interrupts the thing the user is watching is worse than one that waits. It is not
    // close: the update costs ten seconds and a reboot at ANY later moment, while the turn it walked
    // over is work the panel then has to explain the loss of.
    //
    // "Mid-turn" is read widely on purpose — a running turn on any project, and a voice turn that has
    // not finished (which includes the wait for the transcript, because rebooting through that loses
    // audio the user has already spoken). Declining is simply NOT ANSWERING (docs/panel-protocol.md §2): the
    // app offers again on the next hello, which is fifteen seconds away.
    //
    // A QUESTION ON SCREEN counts as mid-turn too, and it is the sharpest case of the three: the agent is
    // stopped, waiting, and the desktop is showing the same card. Rebooting through it does not merely lose
    // work — it takes the panel's answer off the table while a person is looking at it, and the app's own
    // timer gives up 55 seconds later.
    if (ui_any_project_busy() || voice_active() || ui_awaiting_answer()) {
        ESP_LOGI(TAG, "offer of %s declined for now — %s", version,
                 voice_active()        ? "a voice turn is in flight" :
                 ui_awaiting_answer()  ? "a question is waiting to be answered" :
                                         "a turn is running");
        return;
    }

    esp_err_t e = esp_ota_begin(part, size, &s_handle);
    if (e != ESP_OK) {
        s_handle = 0;
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(e));
        panel_client_fw_error("The panel could not prepare its spare firmware slot.");
        return;
    }

    s_part = part;
    s_size = size;
    s_written = 0;
    s_next_report = PROGRESS_EVERY;
    s_last_pct = -1;
    s_last_slice_us = esp_timer_get_time();
    s_busy = true;
    snprintf(s_version, sizeof(s_version), "%s", version);
    snprintf(s_sha, sizeof(s_sha), "%s", sha256);

    display_lock();
    ui_fw_updating(version);
    display_unlock();

    // ACCEPT LAST, and that ordering is the whole of the flow control on this transfer. esp_ota_begin
    // erases the slot, which takes a noticeable moment; nothing is sent until `fw.accept` goes out
    // (docs/panel-protocol.md §2), so doing the erase first means the first slice arrives at a partition that
    // is already ready for it instead of at a task that is busy erasing.
    ESP_LOGW(TAG, "accepting firmware %s (%d bytes) into %s", version, size, part->label);
    panel_client_fw_accept();
}

void fw_on_slice(const uint8_t *data, size_t len)
{
    if (!s_busy) {
        // Not an error to panic about, but not nothing either: an image slice with no accepted offer
        // behind it means the app is sending against a decision this panel did not make.
        ESP_LOGW(TAG, "a %u-byte firmware slice arrived with no offer accepted — dropped", (unsigned)len);
        return;
    }
    if (len == 0) return;
    if (s_written + (int)len > s_size) {
        fail("The update was longer than the offer said it would be.");
        return;
    }

    // `data` points into the decoder's buffer, which is internal RAM — so esp_ota_write gets a DRAM
    // source and takes its 8 KB-per-transaction path. Handing it a PSRAM pointer instead would make
    // esp_flash_write bounce the data through a 32-BYTE stack buffer, which the reference measured at
    // 256x the flash transactions and two to three minutes for one install.
    esp_err_t e = esp_ota_write(s_handle, data, len);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_write at %d/%d: %s", s_written, s_size, esp_err_to_name(e));
        fail("The panel could not write the update to flash.");
        return;
    }
    s_written += (int)len;
    s_last_slice_us = esp_timer_get_time();

    if (s_written >= s_next_report || s_written == s_size) {
        panel_client_fw_progress((uint32_t)s_written);
        s_next_report = s_written + PROGRESS_EVERY;
    }
    const int pct = (int)((int64_t)s_written * 100 / s_size);
    if (pct != s_last_pct) {
        s_last_pct = pct;
        // The panel keeps drawing through this. It scans its frame buffer out of PSRAM continuously and
        // every flash write disables the cache — which is exactly the case CONFIG_SPIRAM_XIP_FROM_PSRAM
        // exists for, and IDF names this scenario in its own words: XIP makes it "feasible to display an
        // OTA progress bar during your application updates". If a future change here ever brings back a
        // strobing panel, check that option before reaching for display_sleep().
        display_lock();
        ui_fw_progress(pct);
        display_unlock();
    }

    if (s_written == s_size) finish();
}

bool fw_in_progress(void)
{
    return s_busy;
}

void fw_tick(void)
{
    if (!s_busy) return;
    if (esp_timer_get_time() - s_last_slice_us < STALL_GIVE_UP_US) return;
    ESP_LOGW(TAG, "no firmware slice for %llds at %d/%d bytes",
             STALL_GIVE_UP_US / 1000000, s_written, s_size);
    fail("The computer stopped sending the update.");
}

void fw_abort(const char *why)
{
    if (!s_busy) return;
    if (s_handle) { esp_ota_abort(s_handle); s_handle = 0; }
    s_busy = false;
    s_part = NULL;
    ESP_LOGW(TAG, "update abandoned at %d/%d bytes — %s", s_written, s_size, why);
    // No fw.error: there is nobody on the other end to read it. The screen still has to be told, or the
    // panel is left showing a progress bar for a transfer that stopped.
    display_lock();
    ui_fw_failed("The computer went away before the update finished.");
    display_unlock();
}
