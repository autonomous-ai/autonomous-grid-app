import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/chat/logic/chat_sessions_controller.dart';
import 'shell_state.dart';

/// Bring the user to a saved chat from outside the app's own UI — the tray menu,
/// a clicked desktop notification.
///
/// All three steps or none of them: selecting the chat without switching the
/// shell to Chat leaves the user on whatever screen they were on, and doing both
/// without raising the window changes something they can't see.
Future<void> revealChat(WidgetRef ref, String id) async {
  ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  ref.read(chatSessionsProvider.notifier).select(id);
  await windowManager.show();
  await windowManager.focus();
}
