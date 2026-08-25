import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_info.dart';
import '../../theme/app_theme.dart';
import 'grid_power_readout.dart';

/// The strip along the bottom of the window: what this grid is made of, and
/// which build of the app is reading it.
///
/// It exists because the top bar was being asked two questions at once. That bar
/// belongs to the *conversation* — its title, its menu, the panels you can open
/// beside it — and the grid's figures are not about the conversation at all.
/// Putting them here splits the window by what a thing is for rather than by
/// where there happened to be room: **the top is what you press, the bottom is
/// what you know**.
///
/// Full-bleed, under the rail as well as the pane, so the window closes on one
/// unbroken line. A strip that started after the sidebar would put a step in the
/// bottom edge at x=284 and read as part of the pane rather than as part of the
/// window.
class AppStatusRail extends StatelessWidget {
  const AppStatusRail({super.key});

  /// Tall enough for an 11.5pt figure with 20px of hit target around it, short
  /// enough to stay furniture. Below ~24 the figures stop clearing their own
  /// contrast floor at a size anyone would read.
  static const double height = 26;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        // The rail's own fill, matching the sidebar it runs under — the two are
        // the same kind of surface (window furniture) and a third tone here
        // would read as a third pane.
        color: AppGlass.sidebarFill,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      child: SizedBox(
        height: height,
        // Less on the right than the left: the version mark carries its own
        // hover inset, so 10 there lands the text on the same optical margin as
        // the readout's 12 on the left.
        child: const Padding(
          padding: EdgeInsets.only(left: 12, right: 10),
          child: Row(
            children: [
              // [Expanded], because the readout reads from both ends: what this
              // grid *is* on the left, what it is *made of* on the right. It
              // owns the gap between them and hands hover to each figure
              // individually, so the empty middle stays inert.
              Expanded(child: GridPowerReadout()),
              _VersionMark(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which build this is, at the end of the rail.
///
/// The quietest thing on the rail on purpose: it answers a question nobody asks
/// until something is wrong, and then it is the first thing they are asked for.
///
/// Quiet is spent on **size and weight, not ink**. [AppPalette.textFaint] is the
/// obvious token for it and measures 3.03:1 dark / 3.17:1 light on the rail's
/// fill — under the 4.5:1 §11 asks of text this small, and the same trap the
/// node panel's percentage column already fell into once. So the ink is
/// secondary (6.50:1 / 5.91:1) and the step down from the figures beside it is
/// half a point of size and a weight class, which costs nothing legible.
///
/// The account menu prints the same string. That is a duplicate, and a
/// deliberate one for now: this is the glanceable copy and that is the one you
/// go looking for. **TODO(BE):** if the menu row is dropped, this becomes the
/// only place a build number can be read, so it has to keep the build suffix in
/// its tooltip.
class _VersionMark extends ConsumerStatefulWidget {
  const _VersionMark();

  @override
  ConsumerState<_VersionMark> createState() => _VersionMarkState();
}

class _VersionMarkState extends ConsumerState<_VersionMark> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Absent until the platform answers. Nothing rather than a placeholder: a
    // rail that printed "v—" for a frame would draw the eye to the one figure
    // that never changes.
    final version = ref.watch(appVersionProvider).asData?.value;
    if (version == null) return const SizedBox.shrink();

    return Tooltip(
      message: 'Grid $version',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
          ),
          child: Text(
            'v$version',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: _hovered
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
              // The digits change under the reader on an update, and a version
              // that reflowed its own width while doing it would nudge the
              // rail's right edge.
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
        ),
      ),
    );
  }
}
