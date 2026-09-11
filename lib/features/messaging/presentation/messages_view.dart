import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../../shared/widgets/section_scaffold.dart';
// For platform_connected_panel.dart, a part of this library.
import '../../../shared/widgets/toast.dart';
import '../../agents/logic/adapters/hermes_tool.dart';
import '../logic/messaging_actions.dart';
import '../logic/messaging_platform.dart';

part 'platform_connect_form.dart';
part 'platform_connected_panel.dart';

/// Talk to this computer from a chat app — Telegram, Discord or Slack.
///
/// The bot runs *here*: your message goes to the assistant on this machine, which
/// answers with the same model as the Chat tab and can read the same files. Two
/// things this screen never hides — only the people you list may message it, and
/// it goes quiet when this computer does.
///
/// Grid answers Telegram itself; Discord and Slack are answered by Hermes's
/// background gateway, so only those two need Hermes installed.
class MessagesView extends StatefulWidget {
  const MessagesView({super.key});

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  MessagingPlatform _platform = MessagingPlatform.telegram;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SectionScaffold(
      title: 'Messages',
      subtitle:
          'Message the assistant from your phone. It answers from this '
          'computer, with your own model — nothing is sent to anyone else.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PlatformPicker(
            selected: _platform,
            onChanged: (platform) => setState(() => _platform = platform),
          ),
          const SizedBox(height: 20),
          Expanded(child: _PlatformPane(platform: _platform)),
        ],
      ),
    );
  }
}

/// Pick which chat app to set up. Each keeps its own connection, so one being
/// live doesn't touch another.
class _PlatformPicker extends StatelessWidget {
  const _PlatformPicker({required this.selected, required this.onChanged});

  final MessagingPlatform selected;
  final ValueChanged<MessagingPlatform> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final platform in MessagingPlatform.values)
          PillChoice(
            label: Text(platform.label),
            icon: platform.icon,
            selected: platform == selected,
            onTap: () => onChanged(platform),
          ),
      ],
    );
  }
}

/// The connect form or connected panel for the chosen platform — whichever its
/// live state calls for.
class _PlatformPane extends ConsumerWidget {
  const _PlatformPane({required this.platform});

  final MessagingPlatform platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(messagingStateProvider(platform));
    final hermesMissing = !ref.watch(hermesInstalledProvider);
    return switch (state) {
      AsyncData(value: final MessagingConnected connected) =>
        PlatformConnectedPanel(
          // Keyed by platform so switching tabs rebuilds fresh, never reusing
          // one platform's state for another.
          key: ValueKey(platform),
          platform: platform,
          connected: connected,
        ),
      AsyncData(value: MessagingDisconnected(host: MessagingHost.hermes))
          when hermesMissing =>
        _NoAgent(platform: platform),
      AsyncData(value: MessagingDisconnected(:final host)) =>
        PlatformConnectForm(
          key: ValueKey(platform),
          platform: platform,
          host: host,
        ),
      AsyncError(:final error) => Text(
        "Couldn't read your ${platform.label} setup: $error",
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
    };
  }
}

/// [platform] is answered by Hermes, and Hermes isn't on this computer.
class _NoAgent extends ConsumerWidget {
  const _NoAgent({required this.platform});

  final MessagingPlatform platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: LucideIcons.botMessageSquare,
      title: "Hermes isn't on this computer",
      message:
          '${platform.label} messages are answered by Hermes, and it isn\'t '
          'installed yet. Install it, then come back here.',
      action: FilledButton(
        // Assistants are installed on the Assistants screen — sending the
        // user to This computer left them on a page with no way to get the
        // very thing this screen just asked for.
        onPressed: () =>
            ref.read(shellSectionProvider.notifier).select(ShellSection.agents),
        child: const Text('Install Hermes'),
      ),
    );
  }
}
