/// [plural] lives in `packages/grid_theme` now, where Grid on a phone and the
/// shared chat drawing (`grid_chat_ui`) can reach it too — a code block's
/// "Show all 1 lines" was the reason. Still importable from here, where the
/// CLI parsers and every screen have always found it.
library;

export 'package:grid_theme/plural.dart';
