/// The box a message is typed into, and what it says while one is in flight.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_send_controller.dart';

/// Types and sends into one chat.
class ChatComposer extends ConsumerStatefulWidget {
  const ChatComposer(this.chatId, {super.key});

  /// Which conversation this sends into.
  final String chatId;

  @override
  ConsumerState<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends ConsumerState<ChatComposer> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final message = _text.text;
    if (message.trim().isEmpty) return;
    // Cleared before the answer, not after: the message is the computer's now,
    // and a box that stays full reads as a send that did not happen.
    _text.clear();
    ref.read(phoneSendProvider(widget.chatId).notifier).send(message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final send = ref.watch(phoneSendProvider(widget.chatId));
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (send case PhoneSendFailed(:final message)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SendButton(
                  working: send is PhoneSendWorking,
                  onSend: _send,
                  onStopWaiting: () => ref
                      .read(phoneSendProvider(widget.chatId).notifier)
                      .stopWaiting(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Send, or — while the computer is answering — a way to stop waiting.
///
/// Stop waiting, not stop the answer: the turn is running on the computer and
/// this button cannot reach it, so a "Stop" here would be a lie about what
/// happens next (§5).
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.working,
    required this.onSend,
    required this.onStopWaiting,
  });

  final bool working;
  final VoidCallback onSend;
  final VoidCallback onStopWaiting;

  @override
  Widget build(BuildContext context) {
    if (!working) {
      return IconButton.filled(
        tooltip: 'Send',
        onPressed: onSend,
        icon: const Icon(Icons.arrow_upward),
      );
    }
    return IconButton(
      tooltip: 'Stop waiting for the answer',
      onPressed: onStopWaiting,
      icon: const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
