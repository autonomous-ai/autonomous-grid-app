/// The explanations the Model Engines page shows in place of something it can't
/// offer — this computer already has its engine, or we're still looking for
/// servers on it.
///
/// Kept together, and apart from the page: they carry no state and no provider
/// reads, and the page's own file is about *which* of them applies. Each one
/// says what's true and what to do about it, rather than a form quietly
/// vanishing.
library;

import 'package:flutter/material.dart';

import '../../../shared/widgets/app_spinner.dart';
import 'engine_block.dart';

/// Shown in place of the add-engine cards once this computer is serving: a
/// machine shares one engine at a time (`connectBlockedReason`), so there is
/// nothing to add until that one stops. One sentence naming what to stop, rather
/// than a set of cards that all say no.
class OneEngineNote extends StatelessWidget {
  const OneEngineNote({super.key, required this.reason});

  /// The whole message, from `connectBlockedReason` — it names the engine that
  /// holds the slot, which is the only thing the user needs from this note.
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EngineSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One engine per computer',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
