/// The chat history and the projects, read from disk for a paired phone.
///
/// Separate from [MobileRpcService] for the reason that class exists at all:
/// **every reply is a projection, built by reading only the fields it may
/// send.** The app's own [ChatStore] parses a conversation completely, which is
/// right for the app and wrong here.
///
/// Two things are deliberately left behind:
///
///  - **a project's `path`**. The phone lists and picks projects by name; the
///    absolute path is this computer's filesystem layout, and a value this code
///    never holds is one it cannot leak.
///  - **a message's `media`**. Attachments are bytes, and the reason the rest of
///    this file is paginated is that bytes are what breaks the channel.
///
/// Flutter-free, like [MobileRpcService], so `tool/pairing_host.dart` can run
/// the whole host outside the app.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';

/// One conversation's header — never its messages.
typedef ChatHeader = ({
  String id,
  String title,
  String model,
  String agent,
  String projectId,
  String updatedAt,
  bool archived,
});

/// One project, as much of it as a phone is shown.
typedef ProjectSummary = ({String id, String name, String model, String agent});

/// One turn in a transcript.
typedef ChatLine = ({String role, String text});

/// A page of a transcript, newest last, and whether older turns exist.
typedef ChatPage = ({List<ChatLine> lines, int total, int offset});

/// How many turns a page holds unless the phone asks for fewer.
///
/// The relay refuses a frame over 8 MB and **ends the connection** rather than
/// dropping it (`Limits.max_frame_bytes`), so a transcript that does not fit is
/// not a truncated screen, it is a phone that falls off the channel. Measured
/// on this machine's history: the largest conversation on disk is 9.37 MB, over
/// the limit on its own, and 4 of 251 are past 800 KB. So a page is a count the
/// phone can page through, and [kMobileChatPageBytes] bounds what a page of
/// pathologically long turns can weigh.
const int kMobileChatPageTurns = 40;

/// The size a page stops growing at, whatever the turn count says.
///
/// Well under the relay's 8 MB: the JSON is sealed into a frame that carries a
/// 24-byte nonce and a 16-byte tag, the phone has to hold the decoded copy, and
/// a page nobody can scroll is not worth the bytes it cost to send.
const int kMobileChatPageBytes = 256 * 1024;

/// Every conversation's header, newest activity first.
///
/// Reads `index.json` — the headers the sidebar is drawn from — and never the
/// transcripts beside it. Reading the folder instead costs, measured by
/// [ChatStore], 50 ms of disk and 137 ms of decode for 119 chats; this file is
/// 73 KB for 251 and it is the only thing a list needs.
///
/// An absent or corrupt index reads as no chats rather than throwing: a
/// computer that has never opened Chat is a normal state, and the phone's empty
/// list already says so.
List<ChatHeader> readChatHeaders({Directory? chatsDir}) {
  final entries = _chatIndexEntries(chatsDir ?? GridPaths.chatsDir);
  final out = [
    for (final entry in entries)
      if (_headerOf(entry) case final ChatHeader header) header,
  ];
  out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return out;
}

/// A page of conversation [id], ending at its newest turn.
///
/// [offset] counts turns from the start, so the phone pages *backwards* by
/// asking for a smaller one. Null when there is no such conversation — which
/// the caller must answer as `not_found`, never as an empty chat: a phone told
/// a chat is empty will happily send the first message into a file this
/// computer does not have.
ChatPage? readChatPage(
  String id, {
  int? limit,
  int? offset,
  Directory? chatsDir,
}) {
  // The id indexes a filename, so it is the one field here an attacker picks.
  // `..` or a slash in it would read a file outside the folder.
  if (!_isChatId(id)) return null;
  final file = chatsDir == null
      ? GridPaths.chatFile(id)
      : File('${chatsDir.path}/$id.json');
  final document = _readJson(file);
  if (document is! Map) return null;
  final messages = document['messages'];
  if (messages is! List) return (lines: const [], total: 0, offset: 0);

  final total = messages.length;
  final want = (limit ?? kMobileChatPageTurns).clamp(1, kMobileChatPageTurns);
  final start = (offset ?? (total - want)).clamp(0, total);
  final lines = <ChatLine>[];
  var bytes = 0;
  for (var index = start; index < total && lines.length < want; index++) {
    final line = _lineOf(messages[index]);
    if (line == null) continue;
    bytes += line.text.length;
    // Checked *after* the first line is taken: a page that stops before it
    // holds anything is a screen the phone can never fill, however long the
    // turn is. One oversized turn is sent alone instead.
    if (bytes > kMobileChatPageBytes && lines.isNotEmpty) break;
    lines.add(line);
  }
  return (lines: lines, total: total, offset: start);
}

/// The projects in `~/.grid/app/projects.json`, without their paths.
///
/// Lenient for the same reason as [readChatHeaders]: a computer with no
/// projects is normal, and a corrupt file is not something the phone can fix.
List<ProjectSummary> readProjectSummaries({File? file}) {
  final document = _readJson(file ?? GridPaths.projectsFile);
  if (document is! List) return const [];
  return [
    for (final project in document)
      if (project is Map && project['id'] is String)
        (
          id: project['id'] as String,
          name: '${project['name'] ?? ''}',
          model: '${project['model'] ?? ''}',
          agent: '${project['agent'] ?? ''}',
        ),
  ];
}

/// The `chats` array in the chat index, or empty when there isn't one.
List<Object?> _chatIndexEntries(Directory chatsDir) {
  final document = _readJson(File('${chatsDir.path}/$kChatIndexName'));
  if (document is! Map) return const [];
  final chats = document['chats'];
  return chats is List ? chats : const [];
}

/// The header [value] describes, or null when it is not one.
ChatHeader? _headerOf(Object? value) {
  if (value is! Map) return null;
  final id = value['id'];
  if (id is! String || id.isEmpty) return null;
  return (
    id: id,
    title: '${value['title'] ?? ''}',
    model: '${value['model'] ?? ''}',
    agent: '${value['agent'] ?? ''}',
    projectId: '${value['projectId'] ?? ''}',
    updatedAt: '${value['updatedAt'] ?? ''}',
    // Present on 93 of this machine's 251 chats and absent on the rest, so its
    // absence is the ordinary case and must not read as malformed.
    archived: value['archivedAt'] != null,
  );
}

/// The turn [value] describes, or null when it carries no text.
///
/// A turn whose only content was a picture comes back as null rather than as an
/// empty bubble: the phone is not shown media (see the library comment), and a
/// blank row claims the assistant said nothing when it did.
ChatLine? _lineOf(Object? value) {
  if (value is! Map) return null;
  final role = value['role'];
  final text = value['text'];
  if (role is! String || text is! String || text.trim().isEmpty) return null;
  return (role: role, text: text);
}

/// Whether [id] is a conversation id and not a path.
///
/// Chat ids are microsecond timestamps, and Telegram's carry a `telegram-`
/// prefix; both are covered by allowing word characters and dashes only.
bool _isChatId(String id) =>
    id.isNotEmpty && id.length <= 64 && RegExp(r'^[\w-]+$').hasMatch(id);

/// [file] decoded, or null when it is absent, unreadable or not JSON.
Object? _readJson(File file) {
  try {
    return jsonDecode(file.readAsStringSync());
  } on Object {
    return null;
  }
}
