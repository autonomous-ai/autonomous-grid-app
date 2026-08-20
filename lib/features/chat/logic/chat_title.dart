import '../../../core/model_reply_text.dart';
import '../../../core/text_preview.dart';
import '../../playground/logic/chat_message.dart';
import 'conversation.dart';

/// The longest a name runs before it's clipped with an ellipsis, for the places
/// that need a cap on the *string* — a scheduled job's name, a device with a
/// frame budget. **Not** for a chat's own title.
///
/// A title used to be cut to this on the way *in*, and the thirty characters
/// past it were gone: the rename field could only ever offer back the stump,
/// which is what it did on 2026-08-20: a title showing the first six words of
/// the ask, with the rest of the sentence nowhere on the machine. Every place a
/// title is drawn already clips it at the width it actually has (`maxLines: 1`,
/// `TextOverflow.ellipsis`), which is a better cut than any number here, so the
/// string is kept whole and the drawing does the clipping.
const int kMaxChatTitleLength = 40;

/// What is left of an opener before dropping it stops being worth it. Below
/// this, "Help me" says more than the two words it was in front of.
const int _minAfterOpener = 12;

/// A name for the chat from the first thing the user asked, cleaned down to the
/// part that says which chat this is. The fallback under both naming passes (the
/// agent's own name for the session, then the model asked in `ChatTitleWriter`)
/// — so it runs on every chat, and is what the sidebar shows for the seconds
/// those two take.
///
/// Falls back to [kNewConversationTitle] when there's nothing to derive from.
String deriveConversationTitle(List<ChatMessage> messages) {
  for (final message in messages) {
    if (message.role != ChatRole.user) continue;
    final title = chatTitleFromLine(firstLinePreview(message.text));
    if (title.isEmpty) continue;
    return title;
  }
  return kNewConversationTitle;
}

/// [raw] as a name worth reading in a narrow row.
///
/// People open a chat with an instruction, not with its subject — "/goal i want
/// you to work on…", "help me edit this…", "check out this…" — so the first
/// thirty characters are the part every chat has in common, and the sidebar ends
/// up listing rows that read identically (issue #37). Each step here drops one
/// kind of noise from the front, where the room is.
///
/// Empty when nothing survives, which the caller reads as "nothing to name it
/// with yet" rather than blanking the chat.
String chatTitleFromLine(String raw) {
  var line = _withoutSlashCommand(raw.trim());
  line = _withoutOpener(line);
  line = _shortUrls(line);
  line = _withoutTrailingPunctuation(_collapsed(line));
  if (line.isEmpty) return '';
  return _capitalized(line);
}

/// What the model answered, as a name — the same shapes [unfenceReply] and
/// [unquoteLine] exist for, plus the "Title:" lead-in that survives being asked
/// for the name alone, and a model that answered with a whole sentence.
///
/// Empty when it answered with nothing usable; the caller then keeps the name
/// the chat already had.
String tidyChatTitle(String raw) {
  final answer = unfenceReply(raw.trim());
  var line = firstLinePreview(answer);
  line = unquoteLine(line.replaceFirst(_leadIn, '').trim());
  line = _withoutTrailingPunctuation(_collapsed(line));
  if (line.isEmpty) return '';
  return _capitalized(line);
}

/// [text] cut to [kMaxChatTitleLength] at a word boundary — a name cut mid-word
/// reads as a different word ("Study roo.dev/quicks…").
String clipChatTitle(String text) {
  if (text.length <= kMaxChatTitleLength) return text;
  final cut = text.substring(0, kMaxChatTitleLength);
  final lastSpace = cut.lastIndexOf(' ');
  // A name with no space worth cutting at (a URL, a path) is cut where it is:
  // better a truncated token than three characters and an ellipsis.
  final kept = lastSpace > kMaxChatTitleLength ~/ 2
      ? cut.substring(0, lastSpace)
      : cut;
  return '${kept.trimRight()}…';
}

/// [title] as the text to hand a rename field.
///
/// New titles are stored whole, so this has nothing to do for them. It stays
/// for the ones named before that: their "…" is [clipChatTitle]'s mark for
/// *where the name was cut*, not part of the name, and a field seeded with it
/// invites the user to keep the ellipsis on purpose. What it cannot do is give
/// those titles back the words that were dropped; nothing can, they were never
/// written down.
String editableChatTitle(String title) {
  final trimmed = title.trimRight();
  if (!trimmed.endsWith('…')) return trimmed;
  return trimmed.substring(0, trimmed.length - 1).trimRight();
}

/// The lead-in a model writes in front of the answer it was asked for alone.
final _leadIn = RegExp(
  r'^(?:chat\s+)?(?:title|name)\s*[:\-]\s*',
  caseSensitive: false,
);

/// Drops a leading slash command, keeping what was asked of it. The command is
/// the one word every chat run through it shares, and it sits exactly where the
/// row has room.
///
/// A message that was *only* the command keeps it — that is all it said.
String _withoutSlashCommand(String line) {
  final match = _slashCommand.firstMatch(line);
  if (match == null) return line;
  final rest = line.substring(match.end).trim();
  return rest.isEmpty ? match.group(1)!.replaceAll('-', ' ') : rest;
}

/// A command, not a path: `/goal study this` is one, `/Users/me/notes.md` is a
/// file the user dropped in and must survive whole. Hence the required space —
/// without it the pattern eats the first segment of every absolute path.
final _slashCommand = RegExp(r'^/([a-z][\w-]*)(?:\s+|$)', caseSensitive: false);

/// Drops the ways a request opens without saying anything about itself, up to
/// three deep ("hey, can you please …").
///
/// Stops as soon as too little would be left: the point is to reach the subject,
/// not to shorten at any cost.
String _withoutOpener(String line) {
  var text = line;
  for (var i = 0; i < 3; i++) {
    final match = _opener.firstMatch(text);
    if (match == null) break;
    final rest = text.substring(match.end).trim();
    if (rest.length < _minAfterOpener) break;
    text = rest;
  }
  return text;
}

/// English only, and that is a real limit: the same noise in another language
/// is not dropped, so a chat opened in one keeps "help me" — in that language —
/// on the front of its name. Longest first, so "can you please" is dropped
/// whole rather than leaving "please" behind.
const List<String> _openers = [
  "i'd like you to",
  'i would like you to',
  'i want you to',
  'i need you to',
  'i want to',
  'i need to',
  'can you please',
  'could you please',
  'would you please',
  'can you',
  'could you',
  'would you',
  'help me to',
  'help me',
  'take a look at',
  'have a look at',
  'check out',
  'look at',
  "let's",
  'please',
  'hello',
  'hey',
  'hi',
  'ok',
  'okay',
  'so',
];

final _opener = RegExp(
  '^(?:${_openers.join('|')})\\b[\\s,:.-]*',
  caseSensitive: false,
);

/// A pasted link, down to the part that says which link it is.
///
/// `https://roo.dev/quickstart` clipped by the row reads `https://roo…`: thirteen
/// characters of scheme, and the name of the thing cut off. Host plus the first
/// segment fits and identifies it.
String _shortUrls(String line) => line.replaceAllMapped(_url, (match) {
  final host = match.group(1)!;
  final path = match.group(2) ?? '';
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    // Everything a query or a fragment carries is machinery, not a subject.
    final plain = segment.split(RegExp('[?#]')).first;
    if (plain.isNotEmpty) return '$host/$plain';
  }
  return host;
});

final _url = RegExp(
  r'https?://(?:www\.)?([^\s/]+)(/[^\s]*)?',
  caseSensitive: false,
);

/// Drops the punctuation a sentence ends on but a name does not. A question mark
/// stays: it is what makes "How do I sign in?" read as the question it was.
String _withoutTrailingPunctuation(String line) =>
    line.replaceFirst(RegExp(r'[\s.,;:!]+$'), '');

String _collapsed(String line) => line.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Titles the first letter, so a sidebar of lowercase asks reads as a list of
/// names. Left alone when the line opens on anything else — a path, a quote, an
/// emoji the user chose.
String _capitalized(String line) {
  if (line.isEmpty) return line;
  final first = line[0];
  return first == first.toUpperCase()
      ? line
      : '${first.toUpperCase()}${line.substring(1)}';
}
