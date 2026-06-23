import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';

/// Chat + media playground. Streaming chat over the relay is Sprint 2; this
/// shows the relay endpoint the client will hit (derived from the credential).
class PlaygroundView extends ConsumerWidget {
  const PlaygroundView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);

    return SectionScaffold(
      title: 'Playground',
      subtitle: network?.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (network != null)
            InfoRow(label: 'Relay endpoint', value: network.relayBaseUrl, mono: true),
          const SizedBox(height: 16),
          const Expanded(
            child: ComingSoon(
              message: 'Streaming chat & media generation over the relay '
                  'land in Sprint 2.',
            ),
          ),
        ],
      ),
    );
  }
}
