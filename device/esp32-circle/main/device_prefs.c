#include "device_prefs.h"

#include <strings.h>   // strcasecmp
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "mbedtls/sha256.h"
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "prefs";

// One namespace, one owner (see the header). The key is short because NVS caps a key at 15 chars and a
// truncated key is a silently different key.
#define PREFS_NS "grid_panel"
#define KEY_BRIGHT "bright"
#define KEY_VLANG  "vlang"
#define KEY_LOCK_ON   "lock_on"
#define KEY_LOCK_SALT "lock_salt"
#define KEY_LOCK_HASH "lock_hash"

// ~60%. The same default the reference used, and it matters that it is not full: a panel that comes up at
// 0xFF on a desk at night is the first thing anyone changes.
#define BRIGHT_DEFAULT 0x99

void device_prefs_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        // The partition is full or was written by a different NVS version. Erasing loses the stored
        // brightness and nothing else — the alternative is refusing to boot over a screen setting.
        ESP_LOGW(TAG, "nvs needs erasing (%s) — preferences reset to defaults", esp_err_to_name(err));
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

uint8_t device_prefs_brightness(void)
{
    nvs_handle_t h;
    uint8_t level = BRIGHT_DEFAULT;
    if (nvs_open(PREFS_NS, NVS_READONLY, &h) == ESP_OK) {
        // Leaves `level` at the default when the key is absent, which is also what a first boot looks
        // like — so there is no separate "never set" state to carry around.
        nvs_get_u8(h, KEY_BRIGHT, &level);
        nvs_close(h);
    }
    return level;
}

void device_prefs_set_brightness(uint8_t level)
{
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READWRITE, &h) != ESP_OK) {
        // Said out loud rather than swallowed: the screen is already at the new level, so the only symptom
        // is that it forgets on the next boot — which reads as the setting not working at all.
        ESP_LOGW(TAG, "could not open nvs — brightness will not survive a reboot");
        return;
    }
    nvs_set_u8(h, KEY_BRIGHT, level);
    nvs_commit(h);
    nvs_close(h);
}

bool device_prefs_voice_lang(char *out, size_t cap)
{
    if (!out || cap == 0) return false;
    out[0] = '\0';
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = cap;
    esp_err_t err = nvs_get_str(h, KEY_VLANG, out, &len);
    nvs_close(h);
    if (err != ESP_OK) { out[0] = '\0'; return false; }
    // A stored empty string is the same as nothing stored. It cannot happen through the setter, but a
    // half-written key from an interrupted commit would otherwise read as "the user chose ''" and stick.
    return out[0] != '\0';
}

void device_prefs_set_voice_lang(const char *lang)
{
    if (!lang || !lang[0]) return;
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGW(TAG, "could not open nvs — the voice language will not survive a reboot");
        return;
    }
    nvs_set_str(h, KEY_VLANG, lang);
    nvs_commit(h);
    nvs_close(h);
}

// SHA-256 over salt then pattern, hex-encoded. The salt is per-device and per-set, so the same pattern on
// two panels stores two different hashes and a stolen hash cannot be matched against a rainbow table of
// the 389,112 possible patterns — which is a small enough space to enumerate in seconds unsalted.
static void lock_hash(const char *salt_hex, const char *pattern, char out_hex[65])
{
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);   // 0 = SHA-256, not SHA-224
    mbedtls_sha256_update(&ctx, (const unsigned char *)salt_hex, strlen(salt_hex));
    mbedtls_sha256_update(&ctx, (const unsigned char *)pattern, strlen(pattern));
    uint8_t digest[32] = { 0 };
    mbedtls_sha256_finish(&ctx, digest);
    mbedtls_sha256_free(&ctx);
    for (int i = 0; i < 32; i++) snprintf(out_hex + i * 2, 3, "%02x", digest[i]);
}

static void read_str(nvs_handle_t h, const char *key, char *dst, size_t cap)
{
    size_t len = cap;
    memset(dst, 0, cap);
    if (nvs_get_str(h, key, dst, &len) != ESP_OK) dst[0] = '\0';
}

void device_prefs_set_lock(const char *pattern)
{
    if (!pattern || !pattern[0]) return;
    uint8_t salt[8];
    esp_fill_random(salt, sizeof(salt));
    char salt_hex[17];
    for (int i = 0; i < 8; i++) snprintf(salt_hex + i * 2, 3, "%02x", salt[i]);
    char hex[65];
    lock_hash(salt_hex, pattern, hex);
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_str(h, KEY_LOCK_SALT, salt_hex);
    nvs_set_str(h, KEY_LOCK_HASH, hex);
    nvs_set_u8(h, KEY_LOCK_ON, 1);
    nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "lock set");
}

bool device_prefs_lock_enabled(void)
{
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    uint8_t on = 0;
    if (nvs_get_u8(h, KEY_LOCK_ON, &on) != ESP_OK) on = 0;
    nvs_close(h);
    return on == 1;
}

bool device_prefs_check_lock(const char *pattern)
{
    if (!pattern || !pattern[0]) return false;
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    char salt_hex[33] = "", want[80] = "";
    read_str(h, KEY_LOCK_SALT, salt_hex, sizeof(salt_hex));
    read_str(h, KEY_LOCK_HASH, want, sizeof(want));
    nvs_close(h);
    // No salt or no hash means nothing was ever set — refuse rather than comparing against "". A lock that
    // opens to any pattern because its own record is half-written is worse than no lock.
    if (!salt_hex[0] || !want[0]) return false;
    char hex[65];
    lock_hash(salt_hex, pattern, hex);
    return strcasecmp(hex, want) == 0;
}

void device_prefs_clear_lock(void)
{
    nvs_handle_t h;
    if (nvs_open(PREFS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, KEY_LOCK_SALT);
    nvs_erase_key(h, KEY_LOCK_HASH);
    nvs_set_u8(h, KEY_LOCK_ON, 0);
    nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "lock cleared");
}
