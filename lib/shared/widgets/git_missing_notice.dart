import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'app_icon_button.dart';
import 'toast.dart';

/// Says Git is needed and how to get it, when the app couldn't fetch one itself.
///
/// Most people never see this: Git arrives in the background. What's left is the
/// machine the app has no build for (Windows today) and the download that
/// couldn't happen — a locked-down network, no disk. Both are the user's to fix,
/// so this gives them the exact command rather than a sentence about it.
///
/// Shared because two screens reach this same dead end — the Git screen under
/// Settings and the Add-a-plugin dialog — and a second copy of the command would
/// be the copy that goes stale. Only [message] differs: each caller says why
/// *it* needs Git.
class GitMissingNotice extends StatelessWidget {
  const GitMissingNotice({super.key, required this.message});

  /// Why this particular screen is blocked, in one sentence. The command below
  /// is the same everywhere, so only the reason is worth saying twice.
  final String message;

  /// The command that installs Git on this platform. Linux has no single one —
  /// name the most common and let the user translate to their own package
  /// manager, rather than guessing their distribution and being wrong.
  static String get command {
    if (Platform.isMacOS) return 'xcode-select --install';
    if (Platform.isWindows) return 'winget install --id Git.Git';
    return 'sudo apt install git';
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(fontSize: 12.5, color: AppPalette.textPrimary),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    command,
                    style: TextStyle(
                      fontFamily: AppFont.mono,
                      fontSize: 12,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
                AppIconButton(
                  icon: Icons.copy_rounded,
                  tooltip: 'Copy command',
                  size: 14,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (!context.mounted) return;
                    ToastScope.show(
                      context,
                      const ToastSpec(message: 'Copied the command.'),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
