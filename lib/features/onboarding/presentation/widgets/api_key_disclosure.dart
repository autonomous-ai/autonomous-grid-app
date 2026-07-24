import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../provider_node/logic/api_engine_catalog.dart';
import '../../../provider_node/logic/api_engine_choices.dart';
import '../../../provider_node/logic/engine_slots.dart';
import '../../../provider_node/logic/serving_engines_provider.dart';
import '../../../provider_node/presentation/api_engine_block.dart';

/// The remaining way in, folded away: a line the user opens only if a key is how
/// they get in.
///
/// Not a third row. Pasting a key is the rarest of the three ways and the only
/// one that asks for something the user has to go and find — as a row of equal
/// weight it made a two-choice screen look like a form. Renders nothing when the
/// installed CLI takes no keys.
class ApiKeyDisclosure extends ConsumerStatefulWidget {
  const ApiKeyDisclosure({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ApiKeyDisclosure> createState() => _ApiKeyDisclosureState();
}

class _ApiKeyDisclosureState extends ConsumerState<ApiKeyDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = keyEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: TextButton(
            onPressed: () => setState(() => _open = !_open),
            // Quiet, not accent: two blue links on a two-choice screen pull the
            // eye away from the choices themselves.
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.textSecondary,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Named for what it opens, not for the one way in it happens to
                // hold today — the CLI's key list is what decides that.
                const Text('More ways to connect'),
                const SizedBox(width: 4),
                // Points down at what it opened — the same turn the choice rows
                // use, so one chevron language runs through the screen.
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  child: const Icon(Icons.expand_more_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ApiEngineForm(
              network: widget.network,
              engines: engines,
              alreadyShared: apiModelsServed(ref.watch(servingEnginesProvider)),
              compact: true,
            ),
          ),
      ],
    );
  }
}
