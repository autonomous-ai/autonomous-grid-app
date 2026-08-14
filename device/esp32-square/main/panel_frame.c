#include "panel_frame.h"

#include <string.h>

uint16_t panel_crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021)
                                 : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

int panel_frame_encode(uint8_t type, const uint8_t *payload, size_t payload_len,
                       uint8_t *out, size_t out_cap)
{
    if (payload_len > PANEL_MAX_PAYLOAD) return -1;
    const size_t total = PANEL_HEADER_BYTES + payload_len + PANEL_CRC_BYTES;
    if (out_cap < total) return -1;

    out[0] = PANEL_MAGIC_0;
    out[1] = PANEL_MAGIC_1;
    out[2] = PANEL_FRAME_VERSION;
    out[3] = type;
    out[4] = (uint8_t)(payload_len & 0xFF);
    out[5] = (uint8_t)((payload_len >> 8) & 0xFF);
    if (payload_len > 0) memcpy(out + PANEL_HEADER_BYTES, payload, payload_len);

    // Covers ver..payload. The magic is a marker, not data — including a
    // constant would add nothing to detect.
    const uint16_t crc =
        panel_crc16(out + 2, PANEL_HEADER_BYTES - 2 + payload_len);
    out[total - 2] = (uint8_t)(crc & 0xFF);
    out[total - 1] = (uint8_t)((crc >> 8) & 0xFF);
    return (int)total;
}

void panel_decoder_init(panel_decoder_t *d)
{
    d->len = 0;
    d->corrupt_frames = 0;
    d->discarded_bytes = 0;
}

void panel_decoder_reset(panel_decoder_t *d)
{
    // Only the partial frame goes. The counters deliberately survive: they exist
    // to show a TREND — a few discarded bytes at every boot is the bootloader
    // and is expected, a steady trickle means the two sides disagree about the
    // format or the cable is bad. Delegating to panel_decoder_init() (which this
    // did) zeroed them on every reconnect, erasing exactly the history that
    // tells those apart, on precisely the link worth measuring.
    d->len = 0;
}

// Take `count` bytes off the front, keeping the rest. Says nothing about why.
static void consume(panel_decoder_t *d, size_t count)
{
    if (count == 0) return;
    if (count >= d->len) {
        d->len = 0;
        return;
    }
    memmove(d->buf, d->buf + count, d->len - count);
    d->len -= count;
}

// Consume bytes that turned out not to be a frame, and say so.
//
// Split from [consume] rather than counting inside it: the bytes of a frame
// that decoded fine are also consumed, and counting those as discarded would
// make the health number read as "this link is full of noise" on a link that
// is working perfectly.
static void discard(panel_decoder_t *d, size_t count)
{
    const size_t dropped = count < d->len ? count : d->len;
    consume(d, count);
    d->discarded_bytes += (uint32_t)dropped;
}

// Offset of the next complete magic, or -1.
//
// Stops one short of the end on purpose: a final lone byte cannot be judged
// yet, and the caller keeps it in case the next read completes the pair.
static int index_of_magic(const panel_decoder_t *d)
{
    for (size_t i = 0; i + 1 < d->len; i++) {
        if (d->buf[i] == PANEL_MAGIC_0 && d->buf[i + 1] == PANEL_MAGIC_1) {
            return (int)i;
        }
    }
    return -1;
}

// Try to take one frame off the front.
//
// Returns true when a frame was emitted (so the caller should try again),
// false when more bytes are needed. Noise is consumed internally rather than
// reported, so the caller never has to tell "wait" from "that was rubbish".
static bool take_front(panel_decoder_t *d, panel_frame_cb cb, void *ctx)
{
    for (;;) {
        const bool head_is_magic =
            d->len >= 2 && d->buf[0] == PANEL_MAGIC_0 &&
            d->buf[1] == PANEL_MAGIC_1;

        if (!head_is_magic) {
            const int at = index_of_magic(d);
            if (at < 0) {
                // Keep a trailing A5: the 5A may simply not have arrived yet.
                const size_t keep =
                    (d->len > 0 && d->buf[d->len - 1] == PANEL_MAGIC_0) ? 1 : 0;
                discard(d, d->len - keep);
                return false;
            }
            discard(d, (size_t)at);
            continue;
        }

        if (d->len < PANEL_HEADER_BYTES) return false;

        const size_t payload_len =
            (size_t)d->buf[4] | ((size_t)d->buf[5] << 8);

        // A length this large cannot be real, so those two bytes were noise
        // rather than a header. Step over one byte and keep hunting; waiting
        // for 64 KB that is never coming would stall the link.
        if (payload_len > PANEL_MAX_PAYLOAD) {
            discard(d, 1);
            continue;
        }

        const size_t total =
            PANEL_HEADER_BYTES + payload_len + PANEL_CRC_BYTES;
        if (d->len < total) return false;

        const uint16_t expected =
            (uint16_t)d->buf[total - 2] | ((uint16_t)d->buf[total - 1] << 8);
        const uint16_t actual =
            panel_crc16(d->buf + 2, PANEL_HEADER_BYTES - 2 + payload_len);

        if (actual != expected) {
            // Drop ONE byte, not the whole frame: the magic may have been a
            // coincidence inside noise, and a genuine frame can begin one byte
            // further in. Dropping the lot would swallow it.
            d->corrupt_frames++;
            discard(d, 1);
            continue;
        }

        if (cb) {
            cb(d->buf[2], d->buf[3], d->buf + PANEL_HEADER_BYTES, payload_len,
               ctx);
        }
        consume(d, total);
        return true;
    }
}

void panel_decoder_feed(panel_decoder_t *d, const uint8_t *data, size_t n,
                        panel_frame_cb cb, void *ctx)
{
    for (size_t i = 0; i < n; i++) {
        // Full and still no frame means the head was never a real one. Making
        // room by dropping the oldest byte keeps the link alive; refusing the
        // new byte instead would wedge it permanently.
        if (d->len == sizeof(d->buf)) discard(d, 1);

        d->buf[d->len++] = data[i];

        // Only worth attempting once a header could be complete. This also
        // keeps the magic scan amortised: it runs on resync, not per byte.
        if (d->len >= PANEL_HEADER_BYTES) {
            while (take_front(d, cb, ctx)) {
                // keep going: one read can complete several frames
            }
        }
    }
}
