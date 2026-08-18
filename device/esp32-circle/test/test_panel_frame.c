// Host test for the framing codec — runs on a laptop with a plain compiler,
// no ESP-IDF and no flash cycle.
//
//   cc -std=c99 -Wall -Wextra -I../main test_panel_frame.c ../main/panel_frame.c \
//      -o /tmp/test_panel_frame && /tmp/test_panel_frame
//
// Reads the SAME vector file as the Dart half
// (lib/infrastructure/panel/panel_frame.dart + test/panel/panel_frame_test.dart),
// so the two implementations are checked against one another rather than each
// against itself.
#include "../main/panel_frame.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

static void ok(const char *what, bool cond)
{
    checks++;
    if (cond) {
        printf("  ok    %s\n", what);
    } else {
        failures++;
        printf("  FAIL  %s\n", what);
    }
}

// ---- what the decoder handed back ----------------------------------------

#define MAX_CAPTURED 8

typedef struct {
    uint8_t version;
    uint8_t type;
    uint8_t payload[PANEL_MAX_PAYLOAD];
    size_t  payload_len;
} captured_t;

typedef struct {
    captured_t frames[MAX_CAPTURED];
    size_t     count;
} capture_ctx_t;

static void on_frame(uint8_t version, uint8_t type, const uint8_t *payload,
                     size_t payload_len, void *ctx)
{
    capture_ctx_t *c = (capture_ctx_t *)ctx;
    if (c->count >= MAX_CAPTURED) return;
    captured_t *f = &c->frames[c->count++];
    f->version = version;
    f->type = type;
    f->payload_len = payload_len;
    if (payload_len > 0) memcpy(f->payload, payload, payload_len);
}

static size_t decode_all(const uint8_t *data, size_t n, capture_ctx_t *out,
                         panel_decoder_t *keep)
{
    panel_decoder_t local;
    panel_decoder_t *d = keep ? keep : &local;
    if (!keep) panel_decoder_init(d);
    memset(out, 0, sizeof(*out));
    panel_decoder_feed(d, data, n, on_frame, out);
    return out->count;
}

// ---- vectors -------------------------------------------------------------

static size_t unhex(const char *hex, uint8_t *out, size_t cap)
{
    size_t n = strlen(hex) / 2;
    if (n > cap) n = cap;
    for (size_t i = 0; i < n; i++) {
        unsigned int byte = 0;
        sscanf(hex + i * 2, "%2x", &byte);
        out[i] = (uint8_t)byte;
    }
    return n;
}

// Split `line` on tabs in place, into at most `max` fields.
//
// NOT strtok: it treats a run of delimiters as one, so an empty field — which
// is exactly what the zero-length-payload vector has — is skipped and every
// later column shifts left by one. That silently turned a passing vector into
// a missing one rather than a failing one.
static int split_tabs(char *line, char **fields, int max)
{
    int n = 0;
    char *p = line;
    fields[n++] = p;
    for (; *p; p++) {
        if (*p == '\t' && n < max) {
            *p = '\0';
            fields[n++] = p + 1;
        } else if (*p == '\n' || *p == '\r') {
            *p = '\0';
            break;
        }
    }
    return n;
}

static void run_vectors(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        printf("  FAIL  cannot open %s\n", path);
        failures++;
        return;
    }

    // Both the payload and the whole frame appear hex-encoded on one line, so
    // the longest line is roughly four times the largest frame. Sizing this to
    // the frame instead truncated the 8 KB vector and split it across two
    // reads, which then parsed as two malformed rows.
    static char line[PANEL_MAX_FRAME * 4 + 512];
    static uint8_t payload[PANEL_MAX_PAYLOAD];
    static uint8_t expected[PANEL_MAX_FRAME];
    static uint8_t encoded[PANEL_MAX_FRAME];
    int vectors = 0;

    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;

        char *fields[4];
        if (split_tabs(line, fields, 4) != 4) continue;
        const char *name = fields[0];
        const char *type_s = fields[1];
        const char *payload_s = fields[2];
        const char *frame_s = fields[3];

        const uint8_t type = (uint8_t)atoi(type_s);
        const size_t payload_len = unhex(payload_s, payload, sizeof(payload));
        const size_t frame_len = unhex(frame_s, expected, sizeof(expected));
        vectors++;

        char label[160];
        const int written = panel_frame_encode(type, payload, payload_len,
                                               encoded, sizeof(encoded));
        snprintf(label, sizeof(label), "encode %s", name);
        ok(label, written == (int)frame_len &&
                      memcmp(encoded, expected, frame_len) == 0);

        capture_ctx_t got;
        snprintf(label, sizeof(label), "decode %s", name);
        ok(label, decode_all(expected, frame_len, &got, NULL) == 1 &&
                      got.frames[0].type == type &&
                      got.frames[0].version == PANEL_FRAME_VERSION &&
                      got.frames[0].payload_len == payload_len &&
                      memcmp(got.frames[0].payload, payload, payload_len) == 0);
    }
    fclose(f);

    // A vector file that failed to parse would otherwise pass silently, having
    // asserted nothing at all.
    ok("loaded the shared vectors (8 of them)", vectors == 8);
}

// ---- behaviour the vectors cannot express --------------------------------

static void run_stream_cases(void)
{
    static uint8_t buf[PANEL_MAX_FRAME];
    static uint8_t scratch[PANEL_MAX_FRAME * 2];
    capture_ctx_t got;

    ok("CRC is the published CCITT-FALSE variant, not a lookalike",
       panel_crc16((const uint8_t *)"123456789", 9) == 0x29B1);

    // Boot noise before the first frame. The ROM and bootloader print to this
    // port before the app owns it, so the far end starts mid-stream every boot.
    const char *noise = "rst:0x1 boot: 0x8 SPIWP:0xee\r\n";
    const size_t noise_len = strlen(noise);
    int n = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"h\"}",
                               9, buf, sizeof(buf));
    memcpy(scratch, noise, noise_len);
    memcpy(scratch + noise_len, buf, (size_t)n);
    panel_decoder_t d;
    panel_decoder_init(&d);
    ok("boot noise is stepped over, not fatal",
       decode_all(scratch, noise_len + (size_t)n, &got, &d) == 1 &&
           got.frames[0].payload_len == 9);
    ok("noise is counted, frame bytes are not",
       d.discarded_bytes == (uint32_t)noise_len && d.corrupt_frames == 0);

    // A serial read returns whatever arrived, so a frame spanning reads is the
    // normal case. Worst case is one byte per read.
    panel_decoder_init(&d);
    memset(&got, 0, sizeof(got));
    for (int i = 0; i < n; i++) {
        panel_decoder_feed(&d, &buf[i], 1, on_frame, &got);
    }
    ok("a frame split one byte per read is assembled", got.count == 1);

    // Two frames in one read.
    int a = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"n\":1}", 7,
                               scratch, sizeof(scratch));
    int b = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"n\":2}", 7,
                               scratch + a, sizeof(scratch) - (size_t)a);
    // {"n":2} — the digit sits at index 5, after {, ", n, ", :
    ok("two frames in one read both come back, in order",
       decode_all(scratch, (size_t)(a + b), &got, NULL) == 2 &&
           got.frames[0].payload[5] == '1' && got.frames[1].payload[5] == '2');

    // One bad frame must cost one bad frame, not the rest of the session.
    n = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"bad\"}",
                           11, scratch, sizeof(scratch));
    scratch[n - 1] ^= 0xFF;
    int good = panel_frame_encode(PANEL_TYPE_JSON,
                                  (const uint8_t *)"{\"t\":\"good\"}", 12,
                                  scratch + n, sizeof(scratch) - (size_t)n);
    panel_decoder_init(&d);
    ok("a corrupt frame is dropped and the next one survives",
       decode_all(scratch, (size_t)(n + good), &got, &d) == 1 &&
           got.frames[0].payload_len == 12 && d.corrupt_frames >= 1);

    // A wrecked length can claim 64 KB; without the ceiling the reader would
    // wait for bytes that never come while real frames queue behind it.
    n = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"x\"}", 9,
                           scratch, sizeof(scratch));
    scratch[4] = 0xFF;
    scratch[5] = 0xFF;
    good = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"aft\"}",
                              11, scratch + n, sizeof(scratch) - (size_t)n);
    ok("a corrupt length does not stall the link",
       decode_all(scratch, (size_t)(n + good), &got, NULL) == 1 &&
           got.frames[0].payload_len == 11);

    // The reader hunts for A5 5A, so a payload containing that pair is exactly
    // where a naive scanner cuts a frame in half and loses both halves.
    const uint8_t tricky[6] = {0x01, PANEL_MAGIC_0, PANEL_MAGIC_1,
                               PANEL_MAGIC_0, PANEL_MAGIC_1, 0x02};
    n = panel_frame_encode(PANEL_TYPE_PCM, tricky, sizeof(tricky), buf,
                           sizeof(buf));
    ok("a payload containing the magic is not split at it",
       decode_all(buf, (size_t)n, &got, NULL) == 1 &&
           got.frames[0].payload_len == sizeof(tricky) &&
           memcmp(got.frames[0].payload, tricky, sizeof(tricky)) == 0);

    // The decoder keeps a trailing A5 rather than dropping it: the 5A may
    // simply not have arrived yet.
    n = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"e\"}", 9,
                           buf, sizeof(buf));
    panel_decoder_init(&d);
    memset(&got, 0, sizeof(got));
    panel_decoder_feed(&d, buf, 1, on_frame, &got);
    panel_decoder_feed(&d, buf + 1, (size_t)n - 1, on_frame, &got);
    ok("a magic split across two reads still opens a frame", got.count == 1);

    // A newer app sending a type this build predates must arrive intact, so
    // the layer above can report a mismatch instead of a dead link.
    n = panel_frame_encode(0x7F, (const uint8_t *)"\x01\x02\x03", 3, buf,
                           sizeof(buf));
    ok("an unknown type still decodes, so version skew is visible",
       decode_all(buf, (size_t)n, &got, NULL) == 1 &&
           got.frames[0].type == 0x7F && got.frames[0].payload_len == 3);

    ok("encoding refuses an oversized payload",
       panel_frame_encode(PANEL_TYPE_PCM, buf, PANEL_MAX_PAYLOAD + 1, scratch,
                          sizeof(scratch)) == -1);

    // Leftover bytes belong to a session that has ended; carrying them across
    // would put a stale half-frame in front of the next device's first.
    n = panel_frame_encode(PANEL_TYPE_JSON, (const uint8_t *)"{\"t\":\"p\"}", 9,
                           buf, sizeof(buf));
    panel_decoder_init(&d);
    memset(&got, 0, sizeof(got));
    panel_decoder_feed(&d, buf, 5, on_frame, &got);
    panel_decoder_reset(&d);
    panel_decoder_feed(&d, buf + 5, (size_t)n - 5, on_frame, &got);
    ok("reset drops a half-frame so a reopened port starts clean",
       got.count == 0);

    // The counters are a TREND, not a tally: a link that reconnects often is
    // exactly the one worth measuring, and zeroing on every reconnect erases
    // the history that separates "the bootloader said hello again" from "these
    // two disagree about the format".
    panel_decoder_init(&d);
    memset(&got, 0, sizeof(got));
    panel_decoder_feed(&d, (const uint8_t *)"rst:0x1 noise", 13, on_frame, &got);
    const uint32_t discarded = d.discarded_bytes;
    panel_decoder_reset(&d);
    ok("reset keeps the counters, because they are a trend not a tally",
       discarded > 0 && d.discarded_bytes == discarded);
    panel_decoder_feed(&d, buf, (size_t)n, on_frame, &got);
    ok("and the next whole frame still decodes", got.count == 1);
}

int main(int argc, char **argv)
{
    const char *vectors =
        argc > 1 ? argv[1] : "test/vectors/panel_frame.txt";
    run_stream_cases();
    run_vectors(vectors);
    printf("\n%d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
