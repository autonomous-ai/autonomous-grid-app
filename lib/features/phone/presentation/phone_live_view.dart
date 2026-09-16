/// The pairing screen once this computer is registered with a relay.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/age_label.dart';
import '../../../infrastructure/pairing_host/device_registry.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/log_view.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../logic/phone_pairing_controller.dart';

/// Registered: hand out a code, see who is paired.
class PhoneLiveView extends ConsumerWidget {
  const PhoneLiveView(this.state, {super.key});

  /// What the controller knows right now.
  final PhonePairingLive state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      const SizedBox(height: 8),
      DetailSection(
        title: 'THIS COMPUTER',
        children: [
          // Says what it is *not*, because the only other copyable string on
          // this screen is the pairing code and this one sits above it with its
          // own copy button. A relay restart leaves the code half missing — and
          // then this is the only thing there is to copy, so it gets pasted
          // into the phone, which refuses it and blames the person.
          AddressRow(
            label: 'Address on the relay — not the code to paste',
            value: state.relayHostId,
          ),
        ],
      ),
      const SizedBox(height: 20),
      _NewCode(state),
      if (state.offer case final offer?) ...[
        const SizedBox(height: 16),
        _Code(offer.toLink()),
      ],
      const SizedBox(height: 24),
      _PairedPhones(state.devices),
      if (state.events.isNotEmpty) ...[
        const SizedBox(height: 24),
        DetailSection(
          title: 'ACTIVITY',
          children: [
            SizedBox(height: 132, child: LogView(lines: state.events)),
          ],
        ),
      ],
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: SoftActionButton(
          label: 'Disconnect from relay',
          onPressed: () => ref.read(phonePairingProvider.notifier).stop(),
        ),
      ),
    ],
  );
}

/// Names a phone and mints its code.
class _NewCode extends ConsumerStatefulWidget {
  const _NewCode(this.state);

  final PhonePairingLive state;

  @override
  ConsumerState<_NewCode> createState() => _NewCodeState();
}

class _NewCodeState extends ConsumerState<_NewCode> {
  final _name = TextEditingController(text: 'My phone');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: LabeledField(
          label: 'Name this phone',
          controller: _name,
          hint: 'My phone',
          enabled: !widget.state.busy,
        ),
      ),
      const SizedBox(width: 12),
      SoftActionButton(
        label: 'Create code',
        filled: true,
        busy: widget.state.busy,
        leading: const Icon(LucideIcons.qrCode, size: 16),
        onPressed: () =>
            ref.read(phonePairingProvider.notifier).createCode(_name.text),
      ),
    ],
  );
}

/// The code itself, and the one thing you do with it.
class _Code extends StatelessWidget {
  const _Code(this.link);

  final String link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DetailSection(
      title: 'PAIRING CODE',
      trailing: CopyButton(value: link),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: SelectableText(
            link,
            maxLines: 4,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'Menlo',
              height: 1.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Text(
            'Good for ten minutes, and for one phone. Paste it into Grid on '
            'the phone, or open it there as a link.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Who holds a token for this computer.
class _PairedPhones extends ConsumerWidget {
  const _PairedPhones(this.devices);

  final List<PairedDevice> devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (devices.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.smartphone,
        title: 'No phones yet',
        message: 'Create a code above, then open it on your phone.',
        compact: true,
      );
    }
    return DetailSection(
      title: 'PAIRED PHONES',
      children: [for (final device in devices) _PhoneRow(device)],
    );
  }
}

class _PhoneRow extends ConsumerWidget {
  const _PhoneRow(this.device);

  final PairedDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  device.everConnected
                      ? 'Last seen '
                            '${ageLabel(DateTime.fromMillisecondsSinceEpoch(device.lastSeenAtMs), DateTime.now())} ago'
                      : 'Has not connected yet',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _MayActSwitch(device),
          TextButton(
            // Says what it does to the phone, not what it does to the row:
            // "Remove" would read as tidying a list, and this stops a device
            // that somebody may still be holding.
            onPressed: () =>
                ref.read(phonePairingProvider.notifier).revoke(device.deviceId),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }
}

/// The switch that decides whether a phone can only look, or can also ask.
///
/// Its own widget so the label and the tooltip live next to the switch they
/// explain — this is the one control on this screen that grants a power rather
/// than showing a fact, and it must read that way.
class _MayActSwitch extends ConsumerWidget {
  const _MayActSwitch(this.device);

  final PairedDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Tooltip(
      message: device.mayAct
          ? 'This phone can send messages to your agents, which run on this '
                'computer.'
          : 'This phone can read your chats. It cannot send anything.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Can send', style: theme.textTheme.bodySmall),
          const SizedBox(width: 6),
          Switch(
            value: device.mayAct,
            onChanged: (allowed) => ref
                .read(phonePairingProvider.notifier)
                .setMayAct(device.deviceId, allowed),
          ),
        ],
      ),
    );
  }
}
