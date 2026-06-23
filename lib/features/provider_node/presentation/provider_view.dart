import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/provider_run_controller.dart';
import 'provider_running_card.dart';

/// Live view of the provider node. Configuration + start lives in the Models
/// tab (detect backend → pick endpoint → start); this monitors the run.
class ProviderView extends ConsumerWidget {
  const ProviderView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    final run = ref.watch(providerRunControllerProvider);

    return SectionScaffold(
      title: 'Provider',
      subtitle: network?.name,
      child: run is ProviderRunActive
          ? ProviderRunningCard(starting: run.starting, log: run.log, logHeight: 460)
          : _Idle(failure: run is ProviderRunFailed ? run.message : null),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle({this.failure});
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (failure != null) ...[
          Text('Last run failed: $failure',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
          const SizedBox(height: 12),
        ],
        const Expanded(
          child: ComingSoon(
            message: 'No provider running.\nSet one up in the Models tab — '
                'detect a backend (Ollama / llama.cpp) and start it.',
          ),
        ),
      ],
    );
  }
}
