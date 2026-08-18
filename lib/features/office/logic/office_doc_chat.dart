import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/folder_name.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/composer_file_request.dart';
import '../../chat/logic/conversation.dart';

/// Which conversation belongs to which document — one chat per file, and one
/// file per chat.
///
/// Opening a document brings its own chat back, so "make the heading shorter"
/// three days later still means the heading in *this* file. Without it the
/// column beside the page showed whatever conversation happened to be open —
/// usually about something else entirely — and the user had to explain the file
/// again every time.
///
/// The pairing itself lives on the conversation ([Conversation.documentPath]),
/// which is what makes it survive quitting the app and what lets the sidebar
/// route a click on a document's chat back to Docs. This notifier owns only the
/// one thing that cannot be written there yet: the **claim**.
final officeDocChatProvider = NotifierProvider<OfficeDocChats, String?>(
  OfficeDocChats.new,
);

/// The claim is this notifier's whole state: the document waiting for a
/// conversation id.
///
/// A new chat has no id until its first message lands — `newChat()` opens a
/// *draft* — so the pairing cannot be written down when the document opens. It
/// is held here and recorded the moment the id appears.
class OfficeDocChats extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(chatSessionsProvider, _onChatsChanged);
    return null;
  }

  /// The conversation paired with [path], or null when the document has none
  /// yet.
  String? conversationFor(String path) {
    for (final chat in ref.read(chatSessionsProvider).conversations) {
      if (chat.documentPath == path) return chat.id;
    }
    return null;
  }

  /// The document [id] belongs to, or null for an ordinary chat — what the
  /// sidebar asks before deciding which screen a chat opens on.
  String? documentOf(String id) {
    for (final chat in ref.read(chatSessionsProvider).conversations) {
      if (chat.id == id) return chat.documentPath;
    }
    return null;
  }

  /// Start the conversation the next document opened will belong to.
  ///
  /// What arriving in Docs from the rail does: the screen offers a document and
  /// the column beside it is a clean compose, waiting to be paired with
  /// whichever file the user chooses.
  void startFresh() {
    state = null;
    ref.read(chatSessionsProvider.notifier).newChat();
  }

  /// Put the conversation for [path] on screen — the one it already has, or a
  /// fresh one claimed for it.
  void openFor(String path) {
    final existing = conversationFor(path);
    if (existing != null) {
      state = null;
      ref.read(chatSessionsProvider.notifier).select(existing);
      return;
    }
    // The document itself on the first message, through the same door a panel
    // uses to put a file on a turn: the assistant should be answering about a
    // file it has read, not about a name it was told. The composer decides what
    // to do with it — it owns the chips and the budget.
    ref.read(composerFileRequestProvider.notifier).add(path);
    final active = ref.read(chatSessionsProvider).active;
    // A conversation begun in Docs before a file was chosen is already the chat
    // beside this document — pair it where it stands, rather than swapping it
    // for a blank one and leaving the user hunting for what they just typed.
    if (active != null && active.documentPath == null) {
      state = null;
      _pair(active.id, path);
      return;
    }
    // Anything else is a chat that already belongs to another file, and a chat
    // never moves house: this document gets its own blank compose, claimed
    // until its first message gives it an id.
    if (active != null) ref.read(chatSessionsProvider.notifier).newChat();
    state = path;
  }

  /// Forget the claim when a document fails to open, so the next conversation
  /// isn't quietly filed under a file nobody could read.
  void cancelClaim() => state = null;

  /// The claimed document's first message has landed — write the pairing down.
  void _onChatsChanged(ChatSessionsState? before, ChatSessionsState after) {
    final path = state;
    if (path == null) return;
    final id = after.activeId;
    if (id == null) return;
    // The claim is spent either way, but only a conversation that did not exist
    // a moment ago can be the one this document's first message just created.
    // An id that was already in the list is the user walking off to another
    // chat, and the claim goes with them rather than landing on it.
    final existed = before?.conversations.any((c) => c.id == id) ?? true;
    state = null;
    if (existed) return;
    _pair(id, path);
  }

  void _pair(String id, String path) {
    final chats = ref.read(chatSessionsProvider.notifier);
    chats.linkToDocument(id, path);
    // Name it after the file, so the sidebar's list reads as documents rather
    // than as a row of "New chat". Renaming also locks the title, which is what
    // stops the model's own name for the conversation replacing it.
    chats.renameConversation(id, folderName(path));
  }
}
