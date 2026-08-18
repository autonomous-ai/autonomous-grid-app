#include "panel_link.h"

#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "link";

// Driver FIFOs.
//
// ⚠️ RX IS NOT A CONVENIENCE — IT IS THE ONLY THING STANDING BETWEEN A SLOW READER AND SILENT DATA
// LOSS. There is no back-pressure on this peripheral. The IDF driver's ISR
// (esp_driver_usb_serial_jtag/src/usb_serial_jtag.c) does:
//
//     rx_fifo_len = usb_serial_jtag_ll_read_rxfifo(buf, USB_SER_JTAG_RX_MAX_SIZE);
//     xRingbufferSendFromISR(rx_ring_buf, buf, rx_fifo_len, &xTaskWoken);
//
// It drains the hardware FIFO unconditionally and ignores the ringbuffer's return value, so a full ring
// means those bytes are simply gone — and because emptying the HW FIFO is what lets the peripheral ACK
// the next OUT packet, the host is never NAK'd and never learns anything went missing. Not reading fast
// enough does not slow the sender down; it shreds the stream.
//
// This was measured, not theorised: at 1024 bytes a firmware transfer died at 0 of 1342160 bytes written.
// Each 8 KB slice takes ~16 ms to reach flash, and at USB full speed ~16 KB arrives while the reader task
// is inside that write — sixteen times what the ring could hold, every slice.
//
// So the rule this file has to keep: RX_BUF ≥ the largest number of bytes the peer may have in flight
// while this task is blocked. The firmware transfer is the only sender that can saturate the link, and
// its credit window is 16 KB (docs/panel-protocol.md, "Firmware update"). 32 KB is that window twice over, for
// scheduling jitter. Changing either number without the other reintroduces exactly this bug.
#define USJ_RX_BUF (32 * 1024)

// TX is sized so the largest thing this link really sends — a PCM chunk of ~1.3 KB plus framing — fits in
// one go and the write does not have to block halfway through a frame waiting for the host to drain.
// (PANEL_MAX_PAYLOAD is 8192, but that is a bound on damage from a corrupt length field, not a size
// anything actually sends.)
#define USJ_TX_BUF 2048

// One read's worth of bytes off the port. Small on purpose: the decoder is where reassembly happens, so
// this only has to be big enough to keep the syscall rate sane, and every byte of it is internal RAM.
#define READ_CHUNK 256

// How long a read parks waiting for bytes. Not a poll interval — the driver wakes the task as soon as
// anything arrives. It only bounds how long the task sleeps with nothing to do, which matters because
// that is also how long a shutdown would take to notice.
#define READ_WAIT_MS 100

// How long a write waits for the host to make room. Finite, and that is the point: an unplugged cable or
// an unopened port fills the TX FIFO and never drains it, and portMAX_DELAY there parks whatever task
// called send() forever. This device is unplugged or in front of a closed app most of the time, so
// "nobody is reading" has to be an ordinary, survivable answer.
#define WRITE_WAIT_MS 100

// Reader task stack. The frame callback runs on this task, so it carries whatever the message layer
// eventually does — JSON parsing, LVGL updates, and since firmware self-update landed, esp_ota_write()
// and an mbedtls SHA-256 over the whole image read back out of flash.
//
// 6 KiB, raised from 4 KiB when those last two arrived. NOT a measured number: nobody has watched this
// task during an install yet. ram_telemetry_periodic() reports its high-water mark by name
// ("panel_link"), and that is the figure to tune from — the reference firmware's own OTA path overflowed
// an 8 KiB stack and shipped devices that could not update themselves, which is the failure this margin
// is against.
#define READER_STACK 6144

static panel_decoder_t s_decoder;
static panel_frame_cb  s_cb;
static void           *s_ctx;
static bool            s_running;

// Serialises the shared encode buffer AND the write, so two tasks sending at once cannot interleave
// halves of two frames onto the wire. A frame split down the middle by a second sender is not something
// the far end can resync out of — both halves have valid magic and neither has a valid CRC.
static SemaphoreHandle_t s_tx_lock;

// 8.2 KB of BSS rather than a stack array (it would not fit) or a malloc (a failed allocation mid-session
// on a microcontroller is a worse outcome than a known, always-paid 8 KB). Same reasoning as the
// decoder's own buffer — see panel_frame.h.
//
// Full-size on purpose, even though nothing sends anything close: at PANEL_MAX_FRAME the encoder can
// never fail for lack of room here, so a -1 from panel_frame_encode means exactly one thing — the
// payload is over the protocol's own limit — instead of two things that need telling apart. The whole
// transport therefore costs ~16.4 KB of internal RAM including the decoder, against ~128 KB free.
static uint8_t s_tx_frame[PANEL_MAX_FRAME];

static void reader_task(void *arg)
{
    (void)arg;
    uint8_t chunk[READ_CHUNK];
    while (1) {
        int n = usb_serial_jtag_read_bytes(chunk, sizeof(chunk), pdMS_TO_TICKS(READ_WAIT_MS));
        if (n <= 0) continue;
        // Never fails and never rejects: everything arriving here is untrusted, starts mid-stream after
        // every boot, and the only useful response to a byte that makes no sense is to step over it.
        panel_decoder_feed(&s_decoder, chunk, (size_t)n, s_cb, s_ctx);
    }
}

bool panel_link_start(panel_frame_cb cb, void *ctx)
{
    if (s_running) return true;

    s_cb  = cb;
    s_ctx = ctx;
    panel_decoder_init(&s_decoder);

    s_tx_lock = xSemaphoreCreateMutex();
    if (!s_tx_lock) {
        ESP_LOGE(TAG, "no memory for the tx lock — link disabled");
        return false;
    }

    usb_serial_jtag_driver_config_t cfg = {
        .tx_buffer_size = USJ_TX_BUF,
        .rx_buffer_size = USJ_RX_BUF,
    };
    esp_err_t err = usb_serial_jtag_driver_install(&cfg);
    if (err != ESP_OK) {
        // Say what it costs. The symptom lands far from here — the panel comes up, draws its screen, and
        // simply never hears from the machine — so the log line has to name the cause itself.
        ESP_LOGE(TAG, "usb_serial_jtag driver install failed (%s) — no link to grid-app",
                 esp_err_to_name(err));
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return false;
    }

    if (xTaskCreate(reader_task, "panel_link", READER_STACK, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "reader task create failed — no link to grid-app");
        usb_serial_jtag_driver_uninstall();
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return false;
    }

    s_running = true;
    ESP_LOGI(TAG, "usb link up on the native port (protocol v%d, max frame %d B)",
             PANEL_FRAME_VERSION, PANEL_MAX_FRAME);
    return true;
}

bool panel_link_send(uint8_t type, const uint8_t *payload, size_t payload_len)
{
    if (!s_running) return false;

    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    int len = panel_frame_encode(type, payload, payload_len, s_tx_frame, sizeof(s_tx_frame));
    if (len < 0) {
        // Over PANEL_MAX_PAYLOAD. A bug on this side, and one the far end could only ever report back as
        // noise, so it has to be caught and named here.
        xSemaphoreGive(s_tx_lock);
        ESP_LOGE(TAG, "refusing to send %u-byte payload (max %d)",
                 (unsigned)payload_len, PANEL_MAX_PAYLOAD);
        return false;
    }
    int wrote = usb_serial_jtag_write_bytes(s_tx_frame, (size_t)len, pdMS_TO_TICKS(WRITE_WAIT_MS));
    xSemaphoreGive(s_tx_lock);

    if (wrote == len) return true;

    // Log at DEBUG, not WARN. "Nobody is draining the port" is this device's resting state, not a fault:
    // it is unplugged, or plugged into a machine with grid-app closed. At WARN the log would be a wall of
    // identical lines whenever nothing is wrong, which is how a log stops being read at all.
    ESP_LOGD(TAG, "short write: %d of %d bytes (host not reading)", wrote, len);
    return false;
}

bool panel_link_host_present(void)
{
    // Guarded on s_running because the driver call is undefined before install, and "no driver" is
    // indistinguishable from "no host" to everything above: both mean nothing can be said on this port.
    return s_running && usb_serial_jtag_is_connected();
}

void panel_link_counters(uint32_t *corrupt_frames, uint32_t *discarded_bytes)
{
    if (corrupt_frames)  *corrupt_frames  = s_decoder.corrupt_frames;
    if (discarded_bytes) *discarded_bytes = s_decoder.discarded_bytes;
}

void panel_link_reset_decoder(void)
{
    panel_decoder_reset(&s_decoder);
}
