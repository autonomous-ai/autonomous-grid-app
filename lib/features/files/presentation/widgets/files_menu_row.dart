import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// One row of a menu this feature opens — the right-click on a file, the one a
/// finished selection offers.
///
/// Hand-rolled per the design system's §5 recipe, because the app defines no
/// `menuButtonTheme`: a bare `MenuItemButton` takes Material's defaults and gets
/// all four wrong at once — square corners, a 14pt label, a grey `onSurface`
/// hover, and an ink ripple the app disables everywhere else.
class FilesMenuRow extends StatefulWidget {
  const FilesMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<FilesMenuRow> createState() => _FilesMenuRowState();
}

class _FilesMenuRowState extends State<FilesMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Drawn in the menu's overlay, off the subtree it was opened from — so it
    // watches the palette itself.
    AppTheme.watch(context);
    // The glyph rests a step below the label and comes up to meet it under the
    // pointer, so a hovered row reads as one lit object rather than a lit label
    // beside a grey icon.
    final tint = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    return Padding(
      // The 6px gutter is what makes the hover highlight read as an inset pill
      // rather than a full-bleed band across the panel.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          onHover: (value) => setState(() => _hovered = value),
          child: SizedBox(
            height: 30,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(
                children: [
                  // Fixed leading slot so labels line up whatever the glyph's
                  // own width.
                  SizedBox(
                    width: 16,
                    child: Icon(widget.icon, size: 15, color: tint),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
