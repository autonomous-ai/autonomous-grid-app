/// The button at the end of the composer: Send, Stop, or a spinner.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_watch.dart';
import '../logic/phone_link_controller.dart';
import '../logic/phone_send_controller.dart';
import '../logic/phone_turn_actions.dart';

/// What the button is for right now.
enum _Role {
  /// Nothing running: send what is typed.
  send,

  /// The message and its files are on their way.
  sending,

  /// An answer is being written, and this computer can be told to stop.
  stop,

  /// An answer is being written on a computer too old to stop from here.
  working,
}

/// Send, or — while the computer answers — Stop.
///
/// A real Stop, not "stop waiting": it ends the turn on the computer, the
/// same as the Stop button there. A computer too old to take that from a
/// phone gets a spinner instead, because a button that looks like Stop and
/// only stops the phone watching is a lie about what happens next (§5).
class ComposerSendButton extends ConsumerWidget {
  const ComposerSendButton({
    required this.chatId,
    required this.onSend,
    super.key,
  });

  /// Which conversation.
  final String chatId;

  /// Sending what is typed.
  final VoidCallback onSend;

  _Role _role(WidgetRef ref) {
    if (ref.watch(phoneSendProvider(chatId)) is PhoneSendSending) {
      return _Role.sending;
    }
    final busy = ref.watch(
      chatWatchProvider(chatId).select((live) => live.busy),
    );
    if (!busy) return _Role.send;
    final canStop = ref.watch(
      phoneLinkProvider.select((state) => shownLink(state)?.canStop ?? false),
    );
    return canStop ? _Role.stop : _Role.working;
  }

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    final refused = await stopAnswer(ref, chatId);
    if (refused == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(refused)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return switch (_role(ref)) {
      _Role.send => IconButton.filled(
        tooltip: 'Send',
        onPressed: onSend,
        iconSize: 18,
        style: IconButton.styleFrom(
          backgroundColor: AppPalette.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.square(40),
        ),
        icon: const Icon(Icons.arrow_upward_rounded),
      ),
      _Role.stop => IconButton.filled(
        tooltip: 'Stop the answer',
        onPressed: () => _stop(context, ref),
        iconSize: 16,
        style: IconButton.styleFrom(
          backgroundColor: AppPalette.textPrimary,
          foregroundColor: AppPalette.windowBg,
          minimumSize: const Size.square(40),
        ),
        icon: const Icon(Icons.stop_rounded),
      ),
      _Role.sending || _Role.working => IconButton(
        tooltip: 'Working on it',
        onPressed: null,
        style: IconButton.styleFrom(minimumSize: const Size.square(40)),
        icon: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppPalette.textFaint,
          ),
        ),
      ),
    };
  }
}
