/// The explanations the Share Intelligence page shows in place of something it
/// can't offer — for now, that we're still looking for servers on this
/// computer.
///
/// Kept apart from the page: it carries no state and no provider reads, and the
/// page's own file is about *when* it applies.
library;

import 'package:flutter/material.dart';

import '../../../shared/widgets/app_spinner.dart';

/// A quiet "still looking" line shown while we probe this computer for running
/// AI engines (Ollama, LM Studio, …), so the not-yet-populated list doesn't read
/// as "nothing found" in the first second or two.
class ScanningForServersNote extends StatelessWidget {
  const ScanningForServersNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const AppSpinner(),
          const SizedBox(width: 10),
          Text(
            'Looking for AI engines on this computer…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
