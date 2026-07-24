import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/engine_run.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'engine_cost_chip.dart';
import 'stop_engine_dialog.dart';

/// The engine's kind, in the product's words — "Local model", "Connected
/// engine", or the hosted provider's name. Public because the section header
/// names the engine it is about to stop with the same words the row uses.
String engineTitle(ServingEngine engine) => switch (engine.kind) {
  EngineKind.local => 'Local model',
  EngineKind.external => 'Connected engine',
  EngineKind.api => switch (engine.apiKind) {
    'openai' => 'OpenAI',
    'codex' => 'ChatGPT / Codex',
    final kind? => kind,
    _ => 'Hosted model',
  },
};

/// One engine in the machine's serving list: what it is, the model(s) it serves,
/// a live dot, and — when the union holds more than one — a Stop that drops just
/// this one, the others staying up. Stop is disabled when the engine carries
/// nothing to match on.
class ServingEngineTile extends ConsumerWidget {
  const ServingEngineTile({
    super.key,
    required this.engine,
    required this.gridId,
    required this.stopping,
    required this.showStop,
  });

  final ServingEngine engine;
  final String gridId;

  /// A stop is already under way on this grid: the row keeps its place — the
  /// engine is still up until `grid leave` returns — but says so instead of
  /// offering a Stop that would race the one in flight.
  final bool stopping;

  /// Whether this row carries its own Stop. False when it's the only engine
  /// serving: "stop just this one" would then mean exactly what the header's
  /// Stop already does, and two buttons for one outcome is the redundancy the
  /// row drops. The per-engine Stop earns its place only once there's another
  /// engine it can be told apart from.
  final bool showStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selector = engine.leaveSelector;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            _icon(engine),
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title and cost share a row, wrapping instead of ellipsising
                // the title when the settings pane is narrow.
                Wrap(
                  spacing: 8,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      engineTitle(engine),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    EngineCostChip(
                      cost: costOfEngineKind(engine.kind),
                      compact: true,
                    ),
                  ],
                ),
                Text(
                  _subtitle(engine),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (stopping)
            const _StoppingLabel()
          else ...[
            _LiveDot(),
            // Only when there's another engine to tell this one apart from —
            // otherwise the header's Stop is the single control (see [showStop]).
            if (showStop)
              IconButton(
                tooltip: selector == null ? 'Use Stop, above' : 'Stop',
                onPressed: selector == null
                    ? null
                    : () => _confirmStop(context, ref, selector),
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmStop(
    BuildContext context,
    WidgetRef ref,
    String selector,
  ) async {
    final ok = await confirmStopEngine(context, what: engineTitle(engine));
    if (!ok) return;
    await ref
        .read(providerRunControllerProvider.notifier)
        .removeEngine(gridId, selector);
  }

  static IconData _icon(ServingEngine engine) => switch (engine.kind) {
    EngineKind.local => Icons.dns_outlined,
    EngineKind.external => Icons.computer_outlined,
    EngineKind.api =>
      engine.apiKind == 'codex'
          ? Icons.smart_toy_outlined
          : Icons.cloud_outlined,
  };

  /// The model(s) it serves — a friendly name for a local GGUF, the endpoint host
  /// for a connected engine, else the advertised model names.
  static String _subtitle(ServingEngine engine) {
    if (engine.kind == EngineKind.local && engine.models.isNotEmpty) {
      return engine.models.map(deriveAdvertiseName).join(', ');
    }
    if (engine.kind == EngineKind.external && engine.endpointUrl != null) {
      final host = engine.endpointUrl!.replaceFirst(RegExp(r'^https?://'), '');
      return engine.models.isEmpty
          ? host
          : '${engine.models.join(', ')} · $host';
    }
    return engine.models.isEmpty ? 'serving' : engine.models.join(', ');
  }
}

/// What the row's Stop turns into while `grid leave` runs: the engine is on its
/// way out and nothing more is to be pressed here. In words, not a bare spinner
/// — a spinner alone reads as "loading", and this is the one moment the user
/// wants to know the click landed.
class _StoppingLabel extends StatelessWidget {
  const _StoppingLabel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 8),
          Text(
            'Stopping…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small green "live" dot — the engine is up and answering on the grid.
class _LiveDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: AppPalette.online, shape: BoxShape.circle),
  );
}
