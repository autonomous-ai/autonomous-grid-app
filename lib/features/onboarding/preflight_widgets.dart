import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/detail_widgets.dart';

/// A copyable one-liner install command, shown in monospace with a copy button.
///
/// Its own widget because the command is the whole point of the "not installed"
/// preflight case: it has to be readable and copyable without a terminal open.
class InstallCommand extends StatelessWidget {
  /// Creates a row showing [command] with a copy button.
  const InstallCommand({super.key, required this.command});

  /// The shell one-liner to display and copy.
  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                fontSize: 12.5,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            onPressed: () => copyToClipboard(context, command),
          ),
        ],
      ),
    );
  }
}

/// The one line of "what we checked" on the preflight screen. Always a failure
/// — the screen only exists when something is wrong — so it carries no
/// ok/not-ok flag, just what went wrong with the helper.
class PreflightCheckRow extends StatelessWidget {
  /// Creates the failed-check row described by [label].
  const PreflightCheckRow({super.key, required this.label});

  /// What was checked, and how it failed.
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.cancel, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}
