import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/log_view.dart';
import '../logic/provider_run_controller.dart';

/// Status + streamed log + Stop for a running provider. Bounded height so it
/// embeds inside scrolling screens.
class ProviderRunningCard extends ConsumerWidget {
  const ProviderRunningCard({
    super.key,
    required this.starting,
    required this.log,
    this.logHeight = 320,
  });

  final bool starting;
  final List<String> log;
  final double logHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (starting)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  const Icon(Icons.dns, color: Colors.green, size: 18),
                const SizedBox(width: 10),
                Text(starting ? 'Starting…' : 'Engine running'),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(providerRunControllerProvider.notifier).stop(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(height: logHeight, child: LogView(lines: log)),
          ],
        ),
      ),
    );
  }
}
