import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../models/logic/advertise_name.dart';

/// A failed start, explained. The raw value we get from the controller is the
/// engine's **last log line**, which for a native crash is a linker diagnostic
/// (`Expected in: <851138D6-…> /System/…/Metal`) — true, but not something a user
/// can act on, and previously rendered as a bare red line above the page heading
/// where it read as "the whole screen is broken".
///
/// This card keeps the exact text (support needs it) but demotes it behind a
/// disclosure, leading instead with a plain-language cause and a way forward.
class EngineFailureCard extends StatelessWidget {
  const EngineFailureCard({
    super.key,
    required this.message,
    required this.onRetry,
    this.engineLabel,
    this.onReinstallEngine,
  });

  /// The raw failure text from `ProviderRunFailed.message` (the engine's last
  /// log line). Shown verbatim under "Show details".
  final String message;

  /// What the failed attempt was serving (`ProviderRunFailed.model`), so the
  /// card names it. Without this the heading says "the local engine" while a
  /// machine may have several — leaving the user to guess which one broke.
  final String? engineLabel;

  final VoidCallback onRetry;

  /// Offered only when the diagnosis points at a broken engine install, since
  /// re-downloading llama.cpp is a heavy action that fixes nothing otherwise.
  final VoidCallback? onReinstallEngine;

  /// [engineLabel] in the form the rest of the app shows models: a local GGUF
  /// filename becomes its advertised name (`Qwen3.6-35B-A3B-UD-IQ3_S.gguf` →
  /// `Qwen3.6-35B-A3B`), an API kind or a comma-joined set is left as it is.
  /// Null when there's nothing worth naming.
  String? get _engineName {
    final label = engineLabel?.trim();
    if (label == null || label.isEmpty) return null;
    return label.endsWith('.gguf') ? deriveAdvertiseName(label) : label;
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final diagnosis = diagnoseEngineFailure(message);
    final error = theme.colorScheme.error;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 20, color: error),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(diagnosis.title, style: theme.textTheme.titleMedium),
                    if (_engineName case final name?) ...[
                      const SizedBox(height: 3),
                      Text(
                        name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: AppFont.mono,
                          fontFamilyFallback: AppFont.monoFallback,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      diagnosis.explanation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
              if (diagnosis.suggestsReinstall && onReinstallEngine != null)
                OutlinedButton.icon(
                  onPressed: onReinstallEngine,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Reinstall engine'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _RawDetails(message: message),
        ],
      ),
    );
  }
}

/// The raw failure text, collapsed. Monospaced and horizontally scrollable: a
/// linker path must not wrap mid-token (it becomes unreadable and unsearchable),
/// and must never widen the page — hence its own scroll view.
class _RawDetails extends StatelessWidget {
  const _RawDetails({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Theme(
      // Drop ExpansionTile's divider lines so it reads as part of the card.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        minTileHeight: 40,
        dense: true,
        title: Text(
          'Show details',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppCard.inset,
              borderRadius: BorderRadius.circular(AppCard.insetRadius),
              border: Border.all(color: AppCard.insetHair),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: AppFont.mono,
                  fontFamilyFallback: AppFont.monoFallback,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A human reading of a raw engine failure.
class EngineFailureDiagnosis {
  const EngineFailureDiagnosis({
    required this.title,
    required this.explanation,
    required this.suggestsReinstall,
  });

  /// One line naming what went wrong, in the user's terms.
  final String title;

  /// What it means and what to do about it.
  final String explanation;

  /// Whether re-downloading the built-in engine is a plausible fix — true only
  /// for failures that point at the engine binary itself.
  final bool suggestsReinstall;
}

/// Map a raw failure message to something a person can act on.
///
/// Deliberately conservative: the patterns below cover the failures we've
/// actually seen, and anything unrecognised falls through to a generic reading
/// that still shows the raw text rather than guessing. Matching is
/// case-insensitive substring, because the wording comes from llama.cpp, dyld
/// and the relay — none of which we control or can rely on to stay stable.
///
/// TODO(review): these strings are matched against third-party output. If a
/// diagnosis ever reads wrong in the wild, correct the pattern here — the raw
/// message is always shown under "Show details", so a mis-diagnosis degrades to
/// a vague-but-honest heading rather than hiding the truth.
EngineFailureDiagnosis diagnoseEngineFailure(String message) {
  final text = message.toLowerCase();

  // A dyld/linker failure loading the native engine — the Metal symbol crash.
  // The engine binary doesn't match this machine's macOS frameworks, which a
  // fresh download of the right build usually fixes.
  if (text.contains('expected in:') ||
      text.contains('symbol not found') ||
      text.contains('dyld') ||
      text.contains('image not found')) {
    return const EngineFailureDiagnosis(
      title: "The local engine couldn't start on this Mac",
      explanation:
          'The built-in engine failed to load a system graphics library it '
          "needs. This usually means the engine build doesn't match this "
          'version of macOS — reinstalling it fetches the right one.',
      suggestsReinstall: true,
    );
  }

  // The engine came up but couldn't hold the model.
  if (text.contains('out of memory') ||
      text.contains('insufficient memory') ||
      text.contains('failed to allocate') ||
      text.contains('unable to allocate')) {
    return const EngineFailureDiagnosis(
      title: 'Not enough memory for this model',
      explanation:
          "The model didn't fit in this computer's memory. Try a smaller "
          'context window, close other heavy apps, or pick a smaller model.',
      suggestsReinstall: false,
    );
  }

  // Port contention the controller's own retry didn't resolve.
  if (text.contains('already in use') || text.contains('address in use')) {
    return const EngineFailureDiagnosis(
      title: 'The port the engine needs is taken',
      explanation:
          'Another app on this computer is holding the port. Trying again '
          'picks a different one.',
      suggestsReinstall: false,
    );
  }

  // The model file itself is unusable — truncated download, wrong format.
  if (text.contains('failed to load model') ||
      text.contains('invalid model') ||
      text.contains('unsupported model') ||
      text.contains('gguf')) {
    return const EngineFailureDiagnosis(
      title: "This model file couldn't be loaded",
      explanation:
          'The engine rejected the model file. It may have downloaded '
          'incompletely — re-downloading it in the model manager usually '
          'fixes this.',
      suggestsReinstall: false,
    );
  }

  // Credential problems on a hosted engine.
  if (text.contains('unauthorized') ||
      text.contains('invalid api key') ||
      text.contains('incorrect api key') ||
      text.contains('401')) {
    return const EngineFailureDiagnosis(
      title: 'The provider rejected your key',
      explanation:
          "Your API key wasn't accepted. Check it hasn't been revoked, then "
          'enter it again below.',
      suggestsReinstall: false,
    );
  }

  // Reachability — the relay, or a hosted vendor.
  if (text.contains('connection refused') ||
      text.contains('network is unreachable') ||
      text.contains('timed out') ||
      text.contains('timeout')) {
    return const EngineFailureDiagnosis(
      title: "Couldn't reach the grid",
      explanation:
          'The connection failed while starting the engine. Check this '
          "computer's internet connection and try again.",
      suggestsReinstall: false,
    );
  }

  return const EngineFailureDiagnosis(
    title: "The engine couldn't start",
    explanation:
        'The last attempt to start an engine on this computer failed. The '
        'details below are the engine’s own report.',
    suggestsReinstall: false,
  );
}
