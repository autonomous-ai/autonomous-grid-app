import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';
import 'shell_state.dart';
import 'widgets/section_view.dart';
import 'widgets/sidebar_item.dart';

/// Everything you set up once, behind one door: the grids you can talk to, what
/// this computer runs, Telegram, and how to point other apps at it.
///
/// It takes the whole window — none of this is daily work, so it doesn't belong
/// in the rail you chat from — and keeps the shape of the grid list it grew out
/// of: pick on the left, work on the right.
class SettingsPane extends ConsumerWidget {
  const SettingsPane({super.key, required this.section});

  /// The settings screen to show — one of [kSettingsSections].
  final ShellSection section;

  /// Under this, a labelled nav column would squeeze the screen it exists to
  /// show (Grids brings its own list), so it drops to icons instead.
  static const double _compactBelow = 1000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Row-first, so the nav rail owns the window's full height and its fill runs
    // from y=0 — under the macOS traffic lights included. The back link rides
    // inside the rail rather than in a bar across the top: a full-width header
    // would have to carry the rail's fill across the content pane too, which is
    // what left the top of the window reading as a separate, lighter band.
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsNav(
            section: section,
            compact: constraints.maxWidth < _compactBelow,
            onSelect: (target) =>
                ref.read(shellSectionProvider.notifier).select(target),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            // The content pane still needs the traffic lights' clearance and a
            // drag handle, but no fill of its own — it sits on the window.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _WindowDragStrip(),
                Expanded(child: SectionView(section: section)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Clearance for the macOS traffic lights, which float over the window because
/// the title bar is [TitleBarStyle.hidden] (see `main.dart`). Settings takes the
/// whole window, so they land on whatever is drawn at the top — the back link
/// drops below them rather than shifting right, which is what lets it align to
/// the rail's own gutter.
const double _trafficLightStrip = 28;

/// The way back, drawn inside the nav rail so it shares the rail's fill.
///
/// Flat on that fill: no pill, no shadow, no "Settings" caption beside it. This
/// is a way out of Settings, not a place — the pill made a back link look like
/// the screen's primary action, and the caption repeated a heading the pane
/// already shows.
class _BackToApp extends ConsumerWidget {
  const _BackToApp({required this.compact});

  /// Matches [_SettingsNav.compact] — icon only, like the rows below it.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void back() {
      final notifier = ref.read(shellSectionProvider.notifier);
      // Return to wherever the user was before Settings, not always Chat —
      // they might have been mid-task in Grids.
      notifier.select(notifier.previous);
    }

    // The rail's own row recipe, so this hovers, highlights and aligns exactly
    // like the nav rows under it. Hand-rolling a TextButton here is what gave
    // the back link a shrink-wrapped pill in the wrong grey: Material tints
    // whatever `overlayColor` it's handed, so a text token used as a hover fill
    // painted far brighter than AppSurface.hoverFill, which SidebarItem uses.
    if (compact) {
      return SidebarItem(
        icon: Icons.arrow_back_rounded,
        label: '',
        tooltip: 'Back to app',
        onTap: back,
      );
    }
    return SidebarItem(
      icon: Icons.arrow_back_rounded,
      label: 'Back to app',
      onTap: back,
    );
  }
}

/// The strip above the content pane: no fill, just the traffic lights' clearance
/// and somewhere to grab the window. The rail draws its own — see
/// [_SettingsNav].
class _WindowDragStrip extends StatelessWidget {
  const _WindowDragStrip();

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: SizedBox(
        height: Platform.isMacOS ? _trafficLightStrip : 0,
        width: double.infinity,
      ),
    );
  }
}

/// The settings list: one row per screen, the open one highlighted, above a
/// field that narrows the list to what you type.
class _SettingsNav extends StatefulWidget {
  const _SettingsNav({
    required this.section,
    required this.compact,
    required this.onSelect,
  });

  final ShellSection section;
  final bool compact;
  final ValueChanged<ShellSection> onSelect;

  static const double width = 224;
  static const double compactWidth = 60;

  @override
  State<_SettingsNav> createState() => _SettingsNavState();
}

class _SettingsNavState extends State<_SettingsNav> {
  String _query = '';

  /// The rows this build offers, narrowed to the query. Matching is a plain
  /// case-insensitive substring of the label — this list is six rows, so
  /// anything cleverer would be machinery no one can feel.
  List<ShellSection> get _visible {
    final q = _query.trim().toLowerCase();
    return [
      for (final target in kSettingsSections)
        if (target.isVisibleForBuild)
          if (q.isEmpty || target.label.toLowerCase().contains(q)) target,
    ];
  }

  @override
  Widget build(BuildContext context) {
    // The rail owns its fill, and this widget spans the window's full height, so
    // the fill runs under the macOS traffic lights too — top and sidebar read as
    // one column rather than two shades.
    AppTheme.watch(context);
    final compact = widget.compact;
    final gutter = compact ? 8.0 : 10.0;
    return Container(
      width: compact ? _SettingsNav.compactWidth : _SettingsNav.width,
      color: AppSurface.recess,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Clearance for the traffic lights, and the rail's share of the
            // window drag handle.
            DragToMoveArea(
              child: SizedBox(
                height: Platform.isMacOS ? _trafficLightStrip : 12,
                width: double.infinity,
              ),
            ),
            // No offset needed: this is a SidebarItem like the rows below, so it
            // brings the same gutter and lines up with them on its own.
            _BackToApp(compact: compact),
            // The field is the labelled rail's alone: at [compactWidth] there is
            // no room for one, and the rows it would filter are icons with no
            // visible label to match against.
            if (!compact) ...[
              const SizedBox(height: 8),
              _SearchField(onChanged: (v) => setState(() => _query = v)),
            ],
            const SizedBox(height: 6),
            Expanded(child: _navList()),
          ],
        ),
      ),
    );
  }

  Widget _navList() {
    final visible = _visible;
    if (visible.isEmpty) return const _NoMatches();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final target in visible)
          if (widget.compact)
            _NavIcon(
              target: target,
              selected: target == widget.section,
              onTap: () => widget.onSelect(target),
            )
          else
            SidebarItem(
              // The rail glyph — the same 300-weight the app's own sidebar
              // uses. This rail was on the default weight, so the two nav
              // columns drew the same icon at two line weights.
              icon: target.thinIcon,
              label: target.label,
              selected: target == widget.section,
              onTap: () => widget.onSelect(target),
            ),
      ],
    );
  }
}

/// The rail's filter. Rim, fill, focus ring and hint all come from
/// `inputDecorationTheme` — see [AppTheme] — so this matches every other field
/// in the app and follows the theme without naming a single colour.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      // The macOS control font the app's other fields use — see [kFieldTextStyle].
      style: kFieldTextStyle,
      decoration: const InputDecoration(
        hintText: 'Search settings…',
        // The field's glyph scale, not the button's — see [kFieldIconSize].
        prefixIcon: Icon(Icons.search_rounded, size: kFieldIconSize),
      ),
    );
  }
}

/// What the rail shows when the query matches nothing — so a typo reads as "no
/// results" rather than a rail that mysteriously emptied.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
      child: Text(
        'No settings match',
        style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}

/// The same row with the label dropped, for a window too narrow to hold both the
/// label column and the screen it opens. The name lives in the tooltip.
class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final ShellSection target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IconButton(
        tooltip: target.label,
        onPressed: onTap,
        // The rail glyph, matching the labelled rows this collapses from — see
        // [_SettingsNav].
        icon: Icon(target.thinIcon, size: 18),
        style: IconButton.styleFrom(
          foregroundColor: selected
              ? AppPalette.textPrimary
              : AppPalette.textSecondary,
          backgroundColor: selected
              ? AppSurface.selectedFill
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
