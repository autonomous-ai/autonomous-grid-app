#include "ui_screens.h"

#include "display.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "ui";

// Fonts are generated C arrays (ui/geist_*.c) linked into this component; LVGL wants a pointer to the
// lv_font_t they define. Declared here rather than in a header because the set a screen uses is a
// property of the screen, and a shared "all fonts" header is how every font ends up in every build.
extern const lv_font_t geist_med_25;   // the line you read from across the room
extern const lv_font_t geist_reg_16;   // the line that tells you what to do about it

// Black, not the LVGL default. The default theme is LIGHT, so an unstyled screen is WHITE — on a 480x480
// panel at arm's length that is a flashbulb, and it is what the panel shows for the few frames between
// the backlight coming on and the first real screen being loaded.
#define COL_BG   lv_color_black()
#define COL_TEXT lv_color_hex(0xF2F2F2)
#define COL_MUTED lv_color_hex(0x8A8A8A)

static lv_obj_t *s_scr;

void ui_screens_init(void)
{
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(s_scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(s_scr, LV_OBJ_FLAG_SCROLLABLE);

    ui_show_not_connected();
    ESP_LOGI(TAG, "screens ready");
}

void ui_show_not_connected(void)
{
    lv_obj_clean(s_scr);

    // Two lines, and the second one is not decoration. "Not connected" on its own leaves the reader with
    // nowhere to go — and on this device the answer really is that simple, because the cable IS the
    // connection: there is no network to check, no pairing to redo, no account to sign into.
    lv_obj_t *title = lv_label_create(s_scr);
    lv_label_set_text(title, "Not connected");
    lv_obj_set_style_text_font(title, &geist_med_25, 0);
    lv_obj_set_style_text_color(title, COL_TEXT, 0);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -16);

    lv_obj_t *hint = lv_label_create(s_scr);
    lv_label_set_text(hint, "Plug into a computer running grid-app");
    lv_obj_set_style_text_font(hint, &geist_reg_16, 0);
    lv_obj_set_style_text_color(hint, COL_MUTED, 0);
    // Wrapped rather than one long line: the panel is 480 px wide and the sentence is not guaranteed to
    // fit at every future wording. A label that overflows its screen truncates silently.
    lv_obj_set_width(hint, 400);
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, 24);

    lv_screen_load(s_scr);
}
