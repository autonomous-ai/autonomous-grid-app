import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/chat/logic/chat_sessions_controller.dart';
import '../../features/office/logic/office_doc_chat.dart';
import '../../features/office/logic/office_doc_controller.dart';
import '../../features/office/logic/office_doc_state.dart';
import 'shell_state.dart';

/// Open the saved chat [id], on the screen that chat belongs to.
///
/// Most chats belong to the Chat screen. A chat started beside a document
/// belongs to **Docs**, and opening it brings the document back with it — the
/// conversation is about a file, so a transcript with no file beside it is half
/// of what the user clicked on. See [Conversation.documentPath].
///
/// In `shared/layouts` rather than in either feature: the sidebar, ⌘K, the tray
/// and the Archived screen all open a chat, and every one of them would
/// otherwise have to know this rule (§1, §3).
void openChat(WidgetRef ref, String id) {
  ref.read(chatSessionsProvider.notifier).select(id);
  final path = ref.read(officeDocChatProvider.notifier).documentOf(id);
  if (path == null) {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    return;
  }
  ref.read(shellSectionProvider.notifier).select(ShellSection.officeDocs);
  // Already on the desk — re-reading it would throw away edits that haven't
  // been saved yet, which is a steep price for clicking a row you were already
  // looking at.
  final open = ref.read(officeDocProvider);
  if (open is OfficeDocOpen && open.path == path) return;
  unawaited(ref.read(officeDocProvider.notifier).open(path));
}

/// Bring the user to a saved chat from outside the app's own UI — the tray menu,
/// a clicked desktop notification.
///
/// All three steps or none of them: selecting the chat without switching the
/// shell to it leaves the user on whatever screen they were on, and doing both
/// without raising the window changes something they can't see.
Future<void> revealChat(WidgetRef ref, String id) async {
  openChat(ref, id);
  await windowManager.show();
  await windowManager.focus();
}
