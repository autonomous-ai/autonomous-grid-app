import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/folder_name.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/composer_file_request.dart';

/// Which conversation belongs to which document.
///
/// Opening a document brings its own chat back, so "make the heading shorter"
/// three days later still means the heading in *this* file. Without it the column
/// beside the page showed whatever conversation happened to be open — usually
/// about something else entirely — and the user had to explain the file again
/// every time.
///
/// Keyed by path. Session state for now: the pairing is lost when the app closes
/// even though the conversations themselves are on disk, because there is nowhere
/// yet that keeps a document's own settings. That is a real gap, and a small one
/// next to inventing a store for it.
final officeDocChatProvider =
    NotifierProvider<OfficeDocChats, Map<String, String>>(OfficeDocChats.new);

class OfficeDocChats extends Notifier<Map<String, String>> {
  /// The document waiting for a conversation id.
  ///
  /// A new chat has no id until its first message lands — `newChat()` opens a
  /// *draft* — so the pairing cannot be written down when the document opens. It
  /// is claimed here and recorded when the id appears.
  String? _claiming;

  @override
  Map<String, String> build() {
    ref.listen(chatSessionsProvider.select((state) => state.activeId), (_, id) {
      final path = _claiming;
      if (path == null || id == null) return;
      _claiming = null;
      state = {...state, path: id};
      // Name it after the file, so the sidebar's list reads as documents rather
      // than as a row of "New chat". Renaming also locks the title, which is
      // what stops the model's own name for the conversation replacing it.
      ref
          .read(chatSessionsProvider.notifier)
          .renameConversation(id, folderName(path));
    });
    return const {};
  }

  /// Put the conversation for [path] on screen — the one it already has, or a
  /// fresh one claimed for it.
  void openFor(String path) {
    final id = state[path];
    final sessions = ref.read(chatSessionsProvider);
    final exists = id != null && sessions.conversations.any((c) => c.id == id);
    if (exists) {
      _claiming = null;
      ref.read(chatSessionsProvider.notifier).select(id);
      return;
    }
    _claiming = path;
    ref.read(chatSessionsProvider.notifier).newChat();
    // The document itself on the first message, through the same door a panel
    // uses to put a file on a turn: the assistant should be answering about a
    // file it has read, not about a name it was told. The composer decides what
    // to do with it — it owns the chips and the budget.
    ref.read(composerFileRequestProvider.notifier).add(path);
  }

  /// Forget the claim when a document fails to open, so the next conversation
  /// isn't quietly filed under a file nobody could read.
  void cancelClaim() => _claiming = null;
}
