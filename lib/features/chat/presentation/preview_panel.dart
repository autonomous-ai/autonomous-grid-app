import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/extension_tile_surface.dart';
import '../../../shared/widgets/panel_visibility.dart';
import '../logic/panel_tabs.dart';
import '../logic/preview_panel.dart';
import 'panel_feature_view.dart';
import 'panel_tab_strip.dart';

/// The work surface beside the conversation: where a review, a terminal, a
/// browser or a file listing opens, so looking at one doesn't push the chat off
/// the screen.
///
/// Two states, and the tab strip decides which:
///
///  - **No tab open** — the launcher, the list of what this panel can open.
///  - **A tab selected** — that feature's own surface. Review is built; the
///    other three answer with `TODO — <name>` until they are.
///
/// Deliberately without panel controls of its own: the buttons that move the
/// panels live together in the top bar. A panel carrying its own copy puts a
/// second set directly under the first, and the user has to work out whether
/// the two rows mean different things. A *surface* inside a tab may carry its
/// own header — that belongs to the surface, not to the panel.
class PreviewPanel extends ConsumerWidget {
  const PreviewPanel({super.key, this.onRaisedSurface = false});

  /// Set when the panel is floating over the chat rather than docked beside it.
  ///
  /// Passed down to anything with a fill of its own: those fills are tuned
  /// against the page, and on a raised surface they measure 1.000:1 — the rows
  /// and the selected tab vanish. [ExtensionTileSurface.onDialog] is the
  /// tuned-for-a-raised-surface variant.
  final bool onRaisedSurface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(panelTabsProvider(PanelHost.preview));
    final active = state.active;
    final open = ref.watch(previewPanelOpenProvider);

    // The slot keeps this mounted while closed so it can slide both ways.
    // Nothing inside a closed panel may hold the keyboard, or a message typed
    // into the chat would go to a terminal nobody can see.
    return ExcludeFocus(
      excluding: !open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Not shown before the first tab exists: a strip holding one "+" is
          // chrome around a screen that already offers the same choice, larger.
          if (state.tabs.isNotEmpty) ...[
            PanelTabStrip(
              host: PanelHost.preview,
              onRaisedSurface: onRaisedSurface,
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: active == null
                ? _Launcher(onRaisedSurface: onRaisedSurface)
                : _OpenTabs(state: state, active: active),
          ),
        ],
      ),
    );
  }
}

/// Every open tab, with the chosen one on top.
///
/// An [IndexedStack] rather than "build whichever tab is active": switching
/// tabs used to throw the old surface away and build the new one from nothing,
/// so the panel blinked — a file tree lost its open folders and its scroll, a
/// diff was laid out again from the top, and a terminal would have lost its
/// session. Here every open tab keeps its element tree; switching only changes
/// which one paints.
///
/// The cost is that a background tab is still laid out. That is the trade a tab
/// *is*: the user opened it, and a tab that has to be rebuilt to be looked at
/// again isn't much better than closing it.
class _OpenTabs extends ConsumerWidget {
  const _OpenTabs({required this.state, required this.active});

  final PanelTabsState state;
  final PanelTab active;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IndexedStack(
    index: state.tabs.indexWhere((tab) => tab.id == active.id),
    sizing: StackFit.expand,
    children: [
      for (final tab in state.tabs)
        // Keyed by the tab, not by its place in the row: closing a tab to the
        // left would otherwise hand its neighbour's state to the wrong
        // surface.
        KeyedSubtree(
          key: ValueKey(tab.id),
          child: _Tab(visible: tab.id == active.id, tab: tab),
        ),
    ],
  );
}

/// One tab's surface, told whether it is the one being looked at.
///
/// A hidden tab is not painted and not hit-tested, but it is still *there* —
/// so its animations are stopped, its fields are taken out of focus traversal,
/// and anything of its own in the overlay is closed (see [PanelTabVisible]).
class _Tab extends ConsumerWidget {
  const _Tab({required this.visible, required this.tab});

  final bool visible;
  final PanelTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PanelTabVisible(
    visible: visible,
    child: TickerMode(
      enabled: visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: panelFeatureView(
          tab,
          host: PanelHost.preview,
          onClose: () => ref
              .read(panelTabsProvider(PanelHost.preview).notifier)
              .close(tab.id),
        ),
      ),
    ),
  );
}

/// What the panel can open — its resting state, before the first tab.
class _Launcher extends ConsumerWidget {
  const _Launcher({required this.onRaisedSurface});

  final bool onRaisedSurface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.read(panelTabsProvider(PanelHost.preview).notifier).open;
    // Centred when there's room, scrolled when there isn't: five rows need
    // ~260px, and a short window with the bottom panel open leaves less than
    // that. `minHeight` is what keeps it centred rather than pinned to the top.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < PanelFeature.values.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _LauncherRow(
                        feature: PanelFeature.values[i],
                        onRaisedSurface: onRaisedSurface,
                        onTap: () => open(PanelFeature.values[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A launcher row.
///
/// Built on [ExtensionTileSurface] — the app's list-tile surface, already
/// carrying the hover lift, the shadow that separates a row from the page, and
/// the raised-surface variant this panel needs when it floats.
class _LauncherRow extends StatelessWidget {
  const _LauncherRow({
    required this.feature,
    required this.onRaisedSurface,
    required this.onTap,
  });

  final PanelFeature feature;
  final bool onRaisedSurface;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final shortcut = feature.shortcut;
    return ExtensionTileSurface(
      onDialog: onRaisedSurface,
      onTap: onTap,
      childBuilder: (context, hovered) => Row(
        children: [
          // The glyph rests a step below the label and comes up to meet it
          // under the pointer, so a hovered row reads as one lit object.
          Icon(
            feature.icon,
            size: 16,
            color: hovered ? AppPalette.textPrimary : AppPalette.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              feature.label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          if (shortcut != null)
            // `textFaint` measures 3.13:1 on the row's fill — under the 4.5:1
            // the app holds itself to. Secondary ink stays quiet enough beside
            // a primary-ink label without being unreadable.
            Text(
              shortcut,
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
            ),
        ],
      ),
    );
  }
}
