import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/messaging_controller.dart';
import '../logic/messaging_platform.dart';

part 'platform_connect_form.dart';
part 'platform_connected_panel.dart';

/// Talk to this computer from a chat app — Telegram, Discord or Slack.
///
/// The bot runs *here*: your message goes to the assistant on this machine, which
/// answers with the same model as the Chat tab and can read the same files. Two
/// things this screen never hides — only the people you list may message it, and
/// it goes quiet when this computer does.
class MessagesView extends ConsumerStatefulWidget {
  const MessagesView({super.key});

  @override
  ConsumerState<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends ConsumerState<MessagesView> {
  MessagingPlatform _platform = MessagingPlatform.telegram;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hermesInstalledProvider)) return const _NoAgent();

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
          _PlatformChip(
            platform: platform,
            selected: platform == selected,
            onTap: () => onChanged(platform),
          ),
      ],
    );
  }
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip({
    required this.platform,
    required this.selected,
    required this.onTap,
  });

  final MessagingPlatform platform;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? AppPalette.accent : AppPalette.textSecondary;
    return Material(
      color: selected ? AppSurface.accentWash : AppSurface.hoverFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(platform.icon, size: 16, color: ink),
              const SizedBox(width: 8),
              Text(
                platform.label,
                style: TextStyle(
                  color: ink,
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
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
    final state = ref.watch(messagingProvider(platform));
    return switch (state) {
      AsyncData(
        value: MessagingConnected(
          :final allowedUsers,
          :final link,
          :final detail,
        ),
      ) =>
        PlatformConnectedPanel(
          // Keyed by platform so switching tabs rebuilds fresh, never reusing
          // one platform's state for another.
          key: ValueKey(platform),
          platform: platform,
          allowedUsers: allowedUsers,
          link: link,
          detail: detail,
        ),
      AsyncData() => PlatformConnectForm(
        key: ValueKey(platform),
        platform: platform,
      ),
      AsyncError(:final error) => Text(
        "Couldn't read your ${platform.label} setup: $error",
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// Nothing on this computer can answer a message yet.
class _NoAgent extends ConsumerWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Messages',
      subtitle: 'Message the assistant from your phone.',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "This computer isn't set up to answer chats yet, so there's "
              'nothing for a bot to answer with.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.engines),
              child: const Text('Set up this computer'),
            ),
          ],
        ),
      ),
    );
  }
}
