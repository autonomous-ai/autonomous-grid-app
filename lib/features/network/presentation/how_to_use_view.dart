import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import 'app_guide_content.dart';

/// Full-page "How to use" — the primary consumer action. For the selected grid,
/// it shows how to connect a real app to it, wrapping the shared
/// [AppGuideContent] in a section frame.
class HowToUseView extends ConsumerWidget {
  const HowToUseView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) {
      return const SectionScaffold(
        title: 'How to use',
        subtitle: 'Connect your apps to a grid.',
        child: ComingSoon(
            message: 'Select a grid first to see how to connect to it.'),
      );
    }
    return SectionScaffold(
      title: 'How to use',
      subtitle: 'Connect your apps to “${network.name}”.',
      child: SingleChildScrollView(
        // Fill the section width (SectionScaffold already pads the frame).
        // Re-key per grid so switching grids resets the guide (app choice and
        // any "Applied" result) instead of showing the previous grid's state.
        child: AppGuideContent(
          key: ValueKey(network.networkId),
          baseUrl: network.relayBaseUrl,
          apiKey: network.relayApiKey,
        ),
      ),
    );
  }
}
