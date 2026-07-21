/// The explanations the Model Engines page shows in place of a form it can't
/// offer — this computer already runs an engine, the built-in one must run
/// alone, the platform can't host it, or we're still looking.
///
/// Kept together, and apart from the page: they carry no state and no provider
/// reads, and the page's own file is about *which* of them applies. Each one
/// says what's true and what to do about it, rather than a form quietly
/// vanishing.
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

/// Shown in place of the built-in Local Engine block when a server on this
/// computer is already serving: this machine runs one engine at a time, so the
/// only way to share something else from here is to stop that one. Carries
/// [connectBlockedReason]'s wording so the page says it once, in one voice.
class OneEngineHereNote extends StatelessWidget {
  const OneEngineHereNote({super.key, required this.reason});

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
                  'One engine at a time on this computer',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '$reason Cloud providers above still work — they run on the '
                  'provider’s computers, not yours.',
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

/// Shown in place of the built-in Local Engine block when other engines are
/// already serving: the built-in can't join them, but a local model reached over
/// its own server (llama-server, Ollama, …) can — so this points there.
class LocalNeedsConnectNote extends StatelessWidget {
  const LocalNeedsConnectNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EngineSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add a local model as a connected engine',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'The built-in local engine can’t run alongside other engines. '
                  'To use a local model here too, run it as a server (Ollama, '
                  'or llama-server) and add it under “Connect your own engine” '
                  'below.',
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

/// Shown on Windows in place of the built-in engine path, which isn't supported
/// there yet — so the user understands why and where to go instead.
class BuiltInUnavailableNote extends StatelessWidget {
  const BuiltInUnavailableNote({super.key});

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
                  'Built-in engine not available on Windows yet',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  "Running a model directly on this Windows computer isn't "
                  'supported yet. You can still connect your own AI server below, '
                  'or use models other people share on the grid from the Playground.',
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
