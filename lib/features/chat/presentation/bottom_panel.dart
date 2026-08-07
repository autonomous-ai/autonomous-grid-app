import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/bottom_panel.dart';

/// The strip under the conversation: where a terminal session will run, so a
/// command and the chat that asked for it are on screen at once.
///
/// It spans the whole pane rather than only the chat column — a terminal put
/// beside the preview panel would be too narrow to read a wrapped command in.
///
/// The session itself isn't built. What's here is the tab strip it will live in,
/// and an empty state that says so: a panel showing an invented shell
/// transcript would be the one kind of placeholder that can be mistaken for
/// working software.
class BottomPanel extends ConsumerWidget {
  const BottomPanel({super.key});

  static const double tabStripHeight = 38;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return Column(
      children: [
        _TabStrip(
          onClose: () => ref.read(bottomPanelOpenProvider.notifier).close(),
        ),
        const Expanded(
          child: EmptyState(
            icon: LucideIcons.squareTerminal,
            title: 'No terminal yet',
            message: 'Running commands from here is not built yet.',
            compact: true,
          ),
        ),
      ],
    );
  }
}

/// Says out loud that a control is a placeholder — see the same helper in
/// `preview_panel.dart` for why a row that swallows the click is worse.
void _todo(BuildContext context, String feature) => ToastScope.show(
  context,
  ToastSpec(message: 'TODO — $feature is not built yet.'),
);

/// The sessions across the top of the panel, and the way out of it.
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: BottomPanel.tabStripHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const _SessionTab(label: 'autonomous-grid'),
            const SizedBox(width: 4),
            AppIconButton(
              icon: Icons.add_rounded,
              size: 15,
              tooltip: 'New terminal',
              onPressed: () => _todo(context, 'A second terminal'),
            ),
            const Spacer(),
            AppIconButton(
              icon: Icons.close_rounded,
              size: 15,
              tooltip: 'Hide bottom panel',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// One terminal session's tab.
///
/// Reads as selected without a second state to compare against, so it carries
/// the raised fill and the primary ink rather than an accent wash — there is
/// nothing here yet for an accent to distinguish it *from*.
class _SessionTab extends StatelessWidget {
  const _SessionTab({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      height: 26,
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: AppGlass.rowFill,
        borderRadius: BorderRadius.circular(8),
        // The fill alone doesn't separate it: against the page it measures
        // 1.22:1 in dark and 1.05:1 in light. Depth here comes from the shadow,
        // which is the whole reason the app can do without borders.
        boxShadow: AppGlass.cardShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.squareTerminal,
            size: 13,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 2),
          AppIconButton(
            icon: Icons.close_rounded,
            size: 12,
            tooltip: 'Close this terminal',
            onPressed: () => _todo(context, 'Closing a terminal'),
          ),
        ],
      ),
    );
  }
}
