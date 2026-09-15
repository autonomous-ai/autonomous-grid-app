/// Settings ▸ Phone — pairing a phone with this computer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../logic/phone_pairing_controller.dart';
import 'phone_live_view.dart';

/// The pairing screen.
class PhoneView extends ConsumerWidget {
  const PhoneView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(phonePairingProvider);
    return SectionScaffold(
      title: 'Phone',
      subtitle:
          'Use Grid from your phone. It reads what this computer tells it, '
          'over a connection only the two of them can read.',
      child: switch (state) {
        PhonePairingOff() => const _Off(),
        PhonePairingStarting() => const _Starting(),
        PhonePairingLive() => PhoneLiveView(state),
        PhonePairingFailed(:final message) => _Failed(message),
      },
    );
  }
}

class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) => const Center(child: AppSpinner());
}

/// Not registered yet: explain, take the address, offer the one action.
class _Off extends ConsumerStatefulWidget {
  const _Off();

  @override
  ConsumerState<_Off> createState() => _OffState();
}

class _OffState extends ConsumerState<_Off> {
  late final _relay = TextEditingController(text: defaultPairingRelayUrl);

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        const SizedBox(height: 8),
        Text(
          'Your phone and this computer both connect out to a relay, which '
          'passes messages between them without being able to read any of '
          'them. Nothing is announced until you connect.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        LabeledField(
          label: 'Relay address',
          controller: _relay,
          hint: 'ws://127.0.0.1:8787',
        ),
        const SizedBox(height: 8),
        Text(
          'The relay has to be running at exactly this address — it signs its '
          'challenges with the address it was started on.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: SoftActionButton(
            label: 'Connect to relay',
            filled: true,
            leading: const Icon(LucideIcons.smartphone, size: 16),
            onPressed: () =>
                ref.read(phonePairingProvider.notifier).start(_relay.text),
          ),
        ),
      ],
    );
  }
}

/// Registration failed. Says what happened and offers the way back.
class _Failed extends ConsumerWidget {
  const _Failed(this.message);

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      const SizedBox(height: 8),
      ErrorBox(message: message),
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerLeft,
        child: SoftActionButton(
          label: 'Try again',
          onPressed: () => ref.read(phonePairingProvider.notifier).stop(),
        ),
      ),
    ],
  );
}
