/// What the app calls each theme choice, in both apps.
///
/// In the shared package for the same reason the palette is: the Mac and the
/// phone both offer this choice now, and two copies of these three words is how
/// one of them ends up saying "Auto" while the other says "System" about the
/// same setting.
library;

import 'package:flutter/material.dart';

/// The name of a theme choice, as the user reads it.
String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
  ThemeMode.system => 'System',
};

/// The glyph for a theme choice — a sun, a moon, and "follow the machine".
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.light => Icons.light_mode_outlined,
  ThemeMode.dark => Icons.dark_mode_outlined,
  ThemeMode.system => Icons.brightness_auto_outlined,
};
