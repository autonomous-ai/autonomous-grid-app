// TEMPORARY bring-up tool — see ui_screenshot.c. Delete both files when the UI review is done.
#pragma once
// Dump the current panel contents to the console as base64 RGB565, framed by SHOT markers.
void ui_screenshot(const char *name);
// Same, at 1/div resolution: div=1 is the full 480x480 panel, for checking whether things collide.
void ui_screenshot_ex(const char *name, int div);
// Walk every screen, dumping one shot each, then return the UI to where it started.
void ui_screenshot_tour(void);
