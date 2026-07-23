import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// A quiet Codex-like list tile surface for plugin and skill rows.
///
/// Lifts a step under the pointer. The rows are dense and mostly identical, so
/// without a hover the eye loses which one it's on — and every row carries
/// controls (a switch, a delete), which have to look reachable before they're
/// reached for.
class ExtensionTileSurface extends StatefulWidget {
  const ExtensionTileSurface({
    super.key,
    required this.child,
    this.onDialog = false,
  });

  final Widget child;

  /// Set when the row sits inside a dialog rather than on a page.
  ///
  /// The default [AppGlass.surfaceFill] is tuned against the page background; on
  /// a dialog it measures **1.023:1** in dark and **1.000:1** in light — the row
  /// disappears completely. [AppGlass.bubbleFill] is the one token that moves the
  /// right way in both themes (lighter than the dark dialog, darker than the
  /// white one), giving 1.074 / 1.111.
  final bool onDialog;

  @override
  State<ExtensionTileSurface> createState() => _ExtensionTileSurfaceState();
}

class _ExtensionTileSurfaceState extends State<ExtensionTileSurface> {
  bool _hovered = false;

  /// The original page behaviour, unchanged: two opaque fills that swap on
  /// hover. Only the dialog variant needed a different treatment.
  Color get _pageFill =>
      _hovered ? AppGlass.surfaceHoverFill : AppGlass.surfaceFill;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        // Matches the job list's hover timing, so a row lifts the same way
        // everywhere in the app.
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: widget.onDialog ? AppGlass.bubbleFill : _pageFill,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppGlass.cardShadow,
        ),
        // On a dialog the hover is a translucent overlay rather than a second
        // opaque fill: surfaceHoverFill is *lighter* than bubbleFill, which in
        // light theme walks the row back toward the white dialog and erases it.
        // The overlay darkens in light and lightens in dark, so hover reads as a
        // lift in both (1.065 / 1.159).
        foregroundDecoration: widget.onDialog && _hovered
            ? BoxDecoration(
                color: AppSurface.hoverFill,
                borderRadius: BorderRadius.circular(14),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A small leading icon well for plugin and skill rows.
///
/// [active] tints the well and its icon with the accent. The icon column repeats
/// the same glyph down the whole list, so as a plain grey square it costs 30px a
/// row and says nothing; tinted, it becomes the column you scan to find what's
/// switched on.
class ExtensionIconBadge extends StatelessWidget {
  const ExtensionIconBadge({
    super.key,
    required this.icon,
    this.active = false,
  });

  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? AppCard.tint18 : AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        icon,
        size: 16,
        color: active ? AppCard.accentStrong : AppPalette.textSecondary,
      ),
    );
  }
}

/// The label over a block of rows — "On 3", "productivity 12".
///
/// Deliberately quiet: uppercase micro-type in the faint ink, no rule, no fill.
/// Its whole job is to break a long column into chapters the eye can skip
/// between; a header that competes with the rows under it defeats that.
class ExtensionSectionHeader extends StatelessWidget {
  const ExtensionSectionHeader({
    super.key,
    required this.label,
    required this.count,
  });

  final String label;

  /// Shown beside the label, so "how many are on?" is answered without counting
  /// switches.
  final int count;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: AppFont.medium,
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact metadata tag shown beside plugin and skill names.
///
/// [muted] drops the accent for a plain grey — for a tag that states a fact
/// ("From Git") rather than a live state. An accent-blue tag on every row reads
/// as sixty things lit up at once.
class ExtensionTag extends StatelessWidget {
  const ExtensionTag({super.key, required this.label, this.muted = false});

  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppCard tokens.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? AppSurface.recess : AppCard.tint18,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: muted ? AppPalette.textSecondary : AppCard.accentStrong,
        ),
      ),
    );
  }
}
