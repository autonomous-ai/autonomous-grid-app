import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/chat_controller.dart';

/// Consumer chat playground — the main consumer action. Sends a message via
/// `grid request chat --network <net> --model <model> --message "<msg>"` and
/// shows the reply. Single-turn (the CLI keeps no history); transcript is local.
class PlaygroundView extends ConsumerStatefulWidget {
  const PlaygroundView({super.key});

  @override
  ConsumerState<PlaygroundView> createState() => _PlaygroundViewState();
}

class _PlaygroundViewState extends ConsumerState<PlaygroundView> {
  final _model = TextEditingController(text: 'Qwen3.6-35B-A3B');
  final _message = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _model.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String networkId) {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    ref.read(chatControllerProvider.notifier).send(
          network: networkId,
          model: _model.text.trim(),
          message: message,
        );
    _message.clear();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final network = ref.watch(selectedNetworkProvider);
    final chat = ref.watch(chatControllerProvider);

    // Keep the transcript pinned to the latest message.
    ref.listen(chatControllerProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    if (network == null) {
      return const SectionScaffold(
        title: 'Playground',
        child: ComingSoon(message: 'Join a network first to start chatting.'),
      );
    }

    return SectionScaffold(
      title: 'Playground',
      subtitle: network.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: 'Model (--model)',
              hintText: 'Qwen3.6-35B-A3B',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: chat.messages.isEmpty
                ? const ComingSoon(message: 'Send a message to the network.')
                : ListView.builder(
                    controller: _scroll,
                    itemCount: chat.messages.length,
                    itemBuilder: (context, i) => _Bubble(message: chat.messages[i]),
                  ),
          ),
          if (chat.error != null) ...[
            const SizedBox(height: 8),
            Text(chat.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          _InputBar(
            controller: _message,
            sending: chat.sending,
            onSend: () => _send(network.networkId),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          message.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 4,
            enabled: !sending,
            onSubmitted: (_) => onSend(),
            decoration: const InputDecoration(
              hintText: 'Message…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: sending ? null : onSend,
            child: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, size: 18),
          ),
        ),
      ],
    );
  }
}
