import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/file_kind.dart';

/// The coloured mark beside a file's name.
///
/// A tree of forty identical grey pages is a list you have to read word by word;
/// a `.dart` that is always cyan and a `.png` that is always violet are things
/// you find by shape and colour before you have read anything. That is the whole
/// job here — the glyph and the hue come from [fileMarkOf], which is where the
/// table of extensions lives.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.path, this.size = 14});

  /// The file's name, or its whole path — [fileMarkOf] takes either.
  final String path;

  final double size;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final mark = fileMarkOf(path);
    return Icon(
      fileGlyphIcon(mark.glyph),
      size: size,
      color: fileAccentColour(mark.accent),
    );
  }
}

/// The glyph for [glyph], at the 300 weight the rest of this panel draws at.
///
/// Lucide's page-shaped `file*` family wherever one fits, so a column of them
/// looks like a column of files rather than a sticker sheet. The six that break
/// the family break it deliberately — a shell script really is a terminal, a
/// database really is a cylinder — and those are the distinctions worth being
/// able to spot from across the panel.
IconData fileGlyphIcon(FileGlyph glyph) => switch (glyph) {
  FileGlyph.code => LucideIcons.fileCode300,
  FileGlyph.script => LucideIcons.squareTerminal300,
  FileGlyph.data => LucideIcons.fileJson300,
  FileGlyph.sheet => LucideIcons.fileSpreadsheet300,
  FileGlyph.markup => LucideIcons.codeXml300,
  FileGlyph.style => LucideIcons.brush300,
  FileGlyph.doc => LucideIcons.fileText300,
  FileGlyph.image => LucideIcons.fileImage300,
  FileGlyph.video => LucideIcons.fileVideo300,
  FileGlyph.audio => LucideIcons.fileAudio300,
  FileGlyph.archive => LucideIcons.fileArchive300,
  FileGlyph.database => LucideIcons.database300,
  FileGlyph.lock => LucideIcons.fileLock300,
  FileGlyph.config => LucideIcons.fileCog300,
  FileGlyph.package => LucideIcons.package300,
  FileGlyph.git => LucideIcons.gitBranch300,
  FileGlyph.binary => LucideIcons.binary300,
  FileGlyph.unknown => LucideIcons.file300,
};

/// The colour for [accent], per theme.
///
/// Two values each, because one hue cannot clear both a white page and a
/// charcoal one — the light values are darkened and the dark ones lightened
/// until every hue passes WCAG 1.4.11's 3:1 for a UI element, measured against
/// the worst surface each theme puts under a row (a *selected* row: `#F2F2F2`
/// light, `#1D1D1D` dark, both composited):
///
/// ```
///           light      on page  on row     dark       on page  on row
/// blue      #2F6FD0     4.88     4.36      #61AEEE     8.29     7.06
/// cyan      #0E7C86     4.95     4.42      #4CC9DE    10.10     8.60
/// green     #3F8F3F     4.03     3.60      #8DC149     9.29     7.91
/// amber     #9A6C00     4.65     4.15      #E0B341    10.08     8.58
/// orange    #C25A11     4.41     3.94      #E8944A     8.26     7.04
/// red       #C2413F     5.09     4.55      #E5726E     6.57     5.59
/// purple    #8250A8     5.73     5.12      #C08BE0     7.55     6.43
/// pink      #C0417A     4.91     4.38      #F07AA8     7.59     6.47
/// ```
///
/// Every one clears 3:1 on both, and all but green and orange in light clear
/// 4.5:1 as well. Checked against `panelBg` too, in case the panel ever stops
/// sitting on the window's own colour: the numbers drop but the worst of them —
/// green on a selected light row — still reads 3.41. Re-measure if you move one:
/// light is the tight side, and a hue that looks right on the dark screenshot is
/// usually the one that fails.
Color fileAccentColour(FileAccent accent) => switch (accent) {
  FileAccent.blue => AppTheme.pick(
    const Color(0xFF2F6FD0),
    const Color(0xFF61AEEE),
  ),
  FileAccent.cyan => AppTheme.pick(
    const Color(0xFF0E7C86),
    const Color(0xFF4CC9DE),
  ),
  FileAccent.green => AppTheme.pick(
    const Color(0xFF3F8F3F),
    const Color(0xFF8DC149),
  ),
  FileAccent.amber => AppTheme.pick(
    const Color(0xFF9A6C00),
    const Color(0xFFE0B341),
  ),
  FileAccent.orange => AppTheme.pick(
    const Color(0xFFC25A11),
    const Color(0xFFE8944A),
  ),
  FileAccent.red => AppTheme.pick(
    const Color(0xFFC2413F),
    const Color(0xFFE5726E),
  ),
  FileAccent.purple => AppTheme.pick(
    const Color(0xFF8250A8),
    const Color(0xFFC08BE0),
  ),
  FileAccent.pink => AppTheme.pick(
    const Color(0xFFC0417A),
    const Color(0xFFF07AA8),
  ),
  // Not a ninth hex pair: a file with no colour of its own is drawn in the ink
  // the rest of the app uses for secondary text, so "we don't know what this
  // is" and "this is quiet" are the same grey everywhere.
  FileAccent.neutral => AppPalette.textSecondary,
};
