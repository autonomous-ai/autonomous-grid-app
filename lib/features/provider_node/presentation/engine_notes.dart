/// The explanations the Model Engines page shows in place of something it can't
/// offer — the built-in engine must run alone, or we're still looking for
/// servers on this computer.
///
/// Kept together, and apart from the page: they carry no state and no provider
/// reads, and the page's own file is about *which* of them applies. Each one
/// says what's true and what to do about it, rather than a form quietly
/// vanishing. Per-card reasons don't live here — those are one sentence in the
/// card's own action slot (see `BlockedNote`).
library;

import 'package:flutter/material.dart';

import '../../../shared/widgets/app_spinner.dart';
import 'engine_block.dart';

/// Shown when the built-in local engine is running: it serves one model and
/// can't share the machine with others (ADR 0007 D4), so adding anything means
/// stopping it first. Honest about the trade rather than offering a failing form.
class LocalEngineExclusiveNote extends StatelessWidget {
  const LocalEngineExclusiveNote({super.key});

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
                  'Your local model runs on its own',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'The built-in local engine serves a single model and can’t '
                  'run alongside others. To run several engines at once, stop '
                  'it above, then add API or connected engines — or run your '
                  'local model as your own server and connect it.',
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

/// A quiet section label above the add-engine blocks, so the page reads as
/// "what's running" then "add another".
class AddEngineHeading extends StatelessWidget {
  const AddEngineHeading({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        'Add an engine',
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
