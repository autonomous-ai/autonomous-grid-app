/// The Phone screen while this computer is sharing: hand out a code, see who
/// holds one.
library;

import 'dart:async';

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
import '../logic/phone_sharing_controller.dart';
import '../logic/phone_sharing_state.dart';

/// Sharing: the code for a new phone, and the phones that already have one.
class PhoneLiveView extends ConsumerWidget {
  const PhoneLiveView(this.state, {super.key});

  /// What the controller knows right now.
  final PhoneSharingLive state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      const SizedBox(height: 8),
      _Address(state),
      const SizedBox(height: 20),
      _AddPhone(state),
      if (state.newest case final device?) ...[
        const SizedBox(height: 16),
        _Code(device),
      ],
      const SizedBox(height: 24),
      _Phones(state.devices),
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
          label: 'Turn off sharing',
          onPressed: () =>
              unawaited(ref.read(phoneSharingProvider.notifier).stop()),
        ),
      ),
    ],
  );
}

/// Where this computer can be reached, and the two things that are true about
/// it.
class _Address extends StatelessWidget {
  const _Address(this.state);

  final PhoneSharingLive state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailSection(
          title: 'THIS COMPUTER',
          children: [
            AddressRow(
              label: 'Reachable at — your phone finds this by itself',
              value: state.publicUrl,
              maxLines: 2,
            ),
            MetaRow(label: 'Known as', value: state.relayHostId),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'This address is new every time sharing starts, and your phones are '
          'told the new one. It is not the code — there is nothing here to type '
          'into a phone.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Names a phone and gives it a code.
class _AddPhone extends ConsumerStatefulWidget {
  const _AddPhone(this.state);

  final PhoneSharingLive state;

  @override
  ConsumerState<_AddPhone> createState() => _AddPhoneState();
}

class _AddPhoneState extends ConsumerState<_AddPhone> {
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
        label: 'Add phone',
        filled: true,
        busy: widget.state.busy,
        leading: const Icon(LucideIcons.smartphone, size: 16),
        onPressed: () => unawaited(
          ref.read(phoneSharingProvider.notifier).addPhone(_name.text),
        ),
      ),
    ],
  );
}

/// The code itself, big enough to read off the screen while typing it.
class _Code extends StatelessWidget {
  const _Code(this.device);

  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final token = tokenOf(device);
    if (token == null) return const SizedBox.shrink();
    return DetailSection(
      title: 'CODE FOR ${device.name.toUpperCase()}',
      trailing: CopyButton(value: token.pretty),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: SelectableText(
            token.pretty,
            style: theme.textTheme.titleLarge?.copyWith(
              fontFamily: 'Menlo',
              letterSpacing: 1.5,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Text(
            'Type this into Grid on that phone. It does not expire, and it is '
            'only for that one phone — anyone holding it can read your chats, '
            'so treat it like a password.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Who holds a code for this computer.
class _Phones extends StatelessWidget {
  const _Phones(this.devices);

  final List<PairedDevice> devices;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.smartphone,
        title: 'No phones yet',
        message: 'Add one above, then type its code into Grid on the phone.',
        compact: true,
      );
    }
    return DetailSection(
      title: 'PHONES',
      children: [for (final device in devices) _PhoneRow(device)],
    );
  }
}

class _PhoneRow extends ConsumerStatefulWidget {
  const _PhoneRow(this.device);

  final PairedDevice device;

  @override
  ConsumerState<_PhoneRow> createState() => _PhoneRowState();
}

class _PhoneRowState extends ConsumerState<_PhoneRow> {
  /// Whether this row is showing its code.
  ///
  /// Hidden by default and per row, so a screenshot of this screen — or somebody
  /// standing behind it — does not hand over every phone at once. Shown on
  /// request rather than never, because the alternative when somebody loses a
  /// code is revoking a phone that works perfectly well.
  var _shown = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final theme = Theme.of(context);
    final token = tokenOf(device);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(_seen(device), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              _MayActSwitch(device),
              if (token != null)
                IconButton(
                  tooltip: _shown ? 'Hide this code' : 'Show this code',
                  icon: Icon(
                    _shown ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 16,
                  ),
                  onPressed: () => setState(() => _shown = !_shown),
                ),
              TextButton(
                // Says what it does to the phone, not what it does to the row:
                // "Remove" would read as tidying a list, and this stops a device
                // somebody may still be holding.
                onPressed: () => unawaited(
                  ref
                      .read(phoneSharingProvider.notifier)
                      .revoke(device.deviceId),
                ),
                child: const Text('Revoke'),
              ),
            ],
          ),
          if (_shown && token != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SelectableText(
                    token.pretty,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'Menlo',
                    ),
                  ),
                  const SizedBox(width: 10),
                  CopyButton(value: token.pretty),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _seen(PairedDevice device) => device.everConnected
      ? 'Last connected '
            '${ageLabel(DateTime.fromMillisecondsSinceEpoch(device.lastSeenAtMs), DateTime.now())} ago'
      : 'Has not connected yet';
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
            onChanged: (allowed) => unawaited(
              ref
                  .read(phoneSharingProvider.notifier)
                  .setMayAct(device.deviceId, allowed),
            ),
          ),
        ],
      ),
    );
  }
}
