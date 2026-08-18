import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../layouts/shell_state.dart';
import '../theme/app_theme.dart';

/// "You have no grid selected, so nothing can answer you yet."
///
/// Shared rather than private to the chat pane, because more than one screen now
/// puts a conversation on it — the Chat section, and the chat beside a document
/// in Docs. Both ask the user the same question, so §5 says they ask it in the
/// same words: two copies would be free to drift into "Choose a grid" and
/// "Select a network" for the same missing thing.
class NoGridNotice extends ConsumerWidget {
  const NoGridNotice({super.key, this.compact = false});

  /// Tightens the mark and the spacing for a narrow column (the chat beside a
  /// document) rather than a whole pane.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Follow the theme so this re-colours the instant the user flips Light/Dark.
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.messagesSquare,
              size: compact ? 28 : 40,
              color: AppPalette.textFaint,
            ),
            SizedBox(height: compact ? 10 : 12),
            Text(
              'Pick a grid to chat with.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            SizedBox(height: compact ? 12 : 14),
            FilledButton(
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.grids),
              child: const Text('Open grids'),
            ),
          ],
        ),
      ),
    );
  }
}
