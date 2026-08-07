import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/extension_tile_surface.dart';
import '../../../shared/widgets/toast.dart';

/// The work surface beside the conversation: where a review, a terminal, a
/// browser or a file listing will open, so looking at one doesn't push the chat
/// off the screen.
///
/// None of those four exist yet. What the panel shows today is the launcher for
/// them — which is also what it will show once they do, because a panel with
/// nothing open should offer what could be rather than sit empty. Every row
/// answers with a "not built yet" toast; see [_todo] for why that beats a row
/// that does nothing at all.
///
/// Deliberately headerless: the buttons that move the panels all live together
/// in the top bar. A panel that carries its own copy of them puts a second set
/// directly under the first, and the user has to work out whether the two rows
/// mean different things.
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key, this.onRaisedSurface = false});

  /// Set when the panel is floating over the chat rather than docked beside it.
  ///
  /// Passed straight through to the rows: their resting fill is tuned against
  /// the page, and on a raised surface it measures 1.000:1 — the rows vanish.
  /// [ExtensionTileSurface.onDialog] is the tuned-for-a-raised-surface variant.
  final bool onRaisedSurface;

  @override
  Widget build(BuildContext context) =>
      _Launcher(onRaisedSurface: onRaisedSurface);
}

/// Says out loud that a control is a placeholder.
///
/// The panel's shape is being agreed before the surfaces behind it are built,
/// and a row that swallows the click is indistinguishable from one that is
/// broken — the app's copy rule (`docs/conventions.md` §5) is that every state
/// is actionable or at least honest about itself.
void _todo(BuildContext context, String feature) => ToastScope.show(
  context,
  ToastSpec(message: 'TODO — $feature is not built yet.'),
);

/// What the panel can open, centred in it — the panel's resting state.
class _Launcher extends StatelessWidget {
  const _Launcher({required this.onRaisedSurface});

  final bool onRaisedSurface;

  /// The shortcuts are labels, not bindings: nothing listens for them yet, and
  /// they are here because a launcher that teaches its keys is the point of
  /// having one. They become real with the surfaces they name.
  static const _items = <_LauncherItem>[
    _LauncherItem(
      icon: LucideIcons.fileCheck,
      label: 'Review',
      shortcut: '⌃⇧G',
    ),
    _LauncherItem(icon: LucideIcons.squareTerminal, label: 'Terminal'),
    _LauncherItem(icon: LucideIcons.globe, label: 'Browser', shortcut: '⌘T'),
    _LauncherItem(icon: LucideIcons.folder, label: 'Files', shortcut: '⌘P'),
    _LauncherItem(
      icon: LucideIcons.messagesSquare,
      label: 'Side chat',
      shortcut: '⌥⌘S',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _LauncherRow(item: _items[i], onRaisedSurface: onRaisedSurface),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One thing the panel can open.
class _LauncherItem {
  const _LauncherItem({required this.icon, required this.label, this.shortcut});

  final IconData icon;
  final String label;

  /// The key it will answer to. Null for the one that hasn't been given one.
  final String? shortcut;
}

/// A launcher row.
///
/// Built on [ExtensionTileSurface] — the app's list-tile surface, already
/// carrying the hover lift, the shadow that separates a row from the page, and
/// the raised-surface variant this panel needs when it floats.
class _LauncherRow extends StatelessWidget {
  const _LauncherRow({required this.item, required this.onRaisedSurface});

  final _LauncherItem item;
  final bool onRaisedSurface;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final shortcut = item.shortcut;
    return ExtensionTileSurface(
      onDialog: onRaisedSurface,
      onTap: () => _todo(context, item.label),
      childBuilder: (context, hovered) => Row(
        children: [
          // The glyph rests a step below the label and comes up to meet it
          // under the pointer, so a hovered row reads as one lit object.
          Icon(
            item.icon,
            size: 16,
            color: hovered ? AppPalette.textPrimary : AppPalette.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.label,
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
