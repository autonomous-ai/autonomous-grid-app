import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/engine_run.dart';
import '../../../shared/theme/app_theme.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'engine_cost_chip.dart';

/// One engine in the machine's serving list: what it is, the model(s) it serves,
/// a live dot, and a Stop that drops just this one from the union (the others
/// keep running). Stop is disabled when the engine carries nothing to match on.
class ServingEngineTile extends ConsumerWidget {
  const ServingEngineTile({
    super.key,
    required this.engine,
    required this.gridId,
  });

  final ServingEngine engine;
  final String gridId;

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
                      _title(engine),
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
          _LiveDot(),
          IconButton(
            tooltip: selector == null ? 'Use Stop all below' : 'Stop',
            onPressed: selector == null
                ? null
                : () => _confirmStop(context, ref, selector),
            icon: const Icon(Icons.stop_circle_outlined, size: 20),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmStop(
    BuildContext context,
    WidgetRef ref,
    String selector,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Stop ${_title(engine)}?'),
        content: const Text(
          'It will stop serving on the grid, so others can no longer use it. '
          'Your other engines keep running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (ok != true) return;
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

  /// The engine's kind, in the product's words — "Local model", "Connected
  /// engine", or the hosted provider's name.
  static String _title(ServingEngine engine) => switch (engine.kind) {
    EngineKind.local => 'Local model',
    EngineKind.external => 'Connected engine',
    EngineKind.api => switch (engine.apiKind) {
      'openai' => 'OpenAI',
      'codex' => 'ChatGPT / Codex',
      final kind? => kind,
      _ => 'Hosted model',
    },
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

/// A small green "live" dot — the engine is up and answering on the grid.
class _LiveDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: AppPalette.online, shape: BoxShape.circle),
  );
}
