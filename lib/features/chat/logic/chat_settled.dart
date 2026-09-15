import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_sessions_controller.dart';

/// How long a chat the app means to carry on is given to start that turn
/// before it is taken as finished after all (the carry-on can bail out, e.g.
/// when the grid went away in between).
const Duration _kCarryOnStart = Duration(seconds: 15);

/// Completes once chat [id] has really finished — for a caller outside the
/// window that has to hand the whole answer on (a Telegram message).
///
/// Idle alone is not finished. When a turn runs out of room the app carries
/// on by itself (`_carryOnAlone`), and that turn starts a moment *after* the
/// reply lands — so a chat that [ChatSessionsController.willCarryOn] is waited
/// on until the next turn begins, and then until that one lands too.
Future<void> chatSettled(Ref ref, String id) async {
  final sessions = ref.read(chatSessionsProvider.notifier);
  while (true) {
    if (ref.read(chatSessionsProvider).sendingFor(id)) {
      await _sendingReaches(ref, id, busy: false);
      continue;
    }
    if (!sessions.willCarryOn(id)) return;
    final began = await _sendingReaches(
      ref,
      id,
      busy: true,
      within: _kCarryOnStart,
    );
    if (!began) return;
  }
}

/// Whether chat [id]'s sending state reached [busy] — within [within], when
/// given.
Future<bool> _sendingReaches(
  Ref ref,
  String id, {
  required bool busy,
  Duration? within,
}) async {
  final reached = Completer<bool>();
  final subscription = ref.listen<bool>(
    chatSessionsProvider.select((chats) => chats.sendingFor(id)),
    (_, now) {
      if (now == busy && !reached.isCompleted) reached.complete(true);
    },
  );
  try {
    if (ref.read(chatSessionsProvider).sendingFor(id) == busy) return true;
    if (within == null) return await reached.future;
    return await reached.future.timeout(within, onTimeout: () => false);
  } finally {
    subscription.close();
  }
}
