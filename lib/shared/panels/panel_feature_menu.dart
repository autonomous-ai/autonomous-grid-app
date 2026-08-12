import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/anchored_menu_position.dart';
import '../widgets/app_icon_button.dart';
import '../widgets/labeled_field.dart';
import 'panel_tabs.dart';

const _menuWidth = 200.0;
const _rowHeight = 34.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: the two drifting apart is what pushes a menu
/// off its button.
const _menuPadding = 5.0;

/// Each row's 1px breathing room above and below, which the gutter recipe adds
/// outside [_rowHeight].
const _rowGap = 1.0;

/// What the menu will measure, summed rather than estimated so
/// [anchoredMenuPosition] lands it *on* the button instead of near it.
///
/// One row per [PanelFeature], no dividers. Counting off `values` rather than a
/// literal is what stops this drifting the day a sixth feature is added — the
/// header menu's own constant is currently three rows short of what it draws.
final _menuSize = Size(
  _menuWidth,
  _menuPadding * 2 + (_rowHeight + _rowGap * 2) * PanelFeature.values.length,
);

/// The "+" on the tab strip, and the menu of things it can open.
///
/// A menu rather than a trip back to the launcher: with tabs already open, the
/// launcher replaces what you are looking at to ask one question, and you lose
/// your place to answer it.
class PanelFeatureMenu extends StatefulWidget {
  const PanelFeatureMenu({super.key, required this.onSelected});

  final ValueChanged<PanelFeature> onSelected;

  @override
  State<PanelFeatureMenu> createState() => _PanelFeatureMenuState();
}

class _PanelFeatureMenuState extends State<PanelFeatureMenu> {
  final _menu = MenuController();

  void _toggle(BuildContext context) {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    // Left-aligned under the button: it sits at the start of the strip, so a
    // menu growing leftwards from it would hang off the panel.
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize,
        margin: 8,
        gap: 6,
      ),
    );
  }

  void _pick(PanelFeature feature) {
    _menu.close();
    widget.onSelected(feature);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      // The shared surface, not a hand-rolled one: it lifts the fill clear of
      // *both* grounds this menu can open over — the page when the panel is
      // docked, a raised surface when it floats.
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      // Sized, not just floored: left to size itself the panel drew 223 against
      // the 200 [_menuSize] predicts, and that difference is how far a menu
      // near the window's edge hangs past it before Flutter's own clamp reels
      // it back.
      menuChildren: [
        SizedBox(
          width: _menuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final feature in PanelFeature.values)
                _FeatureMenuItem(
                  feature: feature,
                  onPressed: () => _pick(feature),
                ),
            ],
          ),
        ),
      ],
      builder: (context, controller, _) => AppIconButton(
        icon: Icons.add_rounded,
        size: 15,
        tooltip: 'Open something else',
        onPressed: () => _toggle(context),
      ),
    );
  }
}

/// One menu row, hand-rolled per the design system's §5 recipe: the app has no
/// `menuButtonTheme`, so a bare `MenuItemButton` would take Material's defaults
/// (square corners, a 14pt label, a grey `onSurface` hover, an ink ripple).
class _FeatureMenuItem extends StatefulWidget {
  const _FeatureMenuItem({required this.feature, required this.onPressed});

  final PanelFeature feature;
  final VoidCallback onPressed;

  @override
  State<_FeatureMenuItem> createState() => _FeatureMenuItemState();
}

class _FeatureMenuItemState extends State<_FeatureMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Lives in the MenuAnchor's overlay, detached from the strip's subtree —
    // so it watches the palette itself.
    AppTheme.watch(context);
    // The glyph rests a step below the label and comes up to meet it under the
    // pointer, so a hovered row reads as one lit object rather than a lit label
    // beside a grey icon.
    final tint = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    final shortcut = widget.feature.shortcut;

    return Padding(
      // The 6px gutter is what makes the hover highlight read as an inset pill
      // rather than a full-bleed band across the panel.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: _rowGap),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppSurface.hoverFill,
          // The app's menus have no ink ripple; MenuItemButton brought one.
          splashFactory: NoSplash.splashFactory,
          onHover: (value) => setState(() => _hovered = value),
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(
                children: [
                  // Fixed 16px leading slot so labels line up whatever the
                  // glyph's own width.
                  SizedBox(
                    width: 16,
                    child: Icon(widget.feature.icon, size: 16, color: tint),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.feature.label,
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
                  if (shortcut != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      shortcut,
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
