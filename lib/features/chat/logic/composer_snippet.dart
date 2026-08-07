import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The most text one selection may carry onto a message.
///
/// Well under a whole file's [kFileTextBudget]: a selection is meant to be the
/// part worth pointing at, and somebody who selected all of a 5,000-line file
/// wanted the file — which the chip beside this one already does better.
const int kSnippetBudget = 4000;

/// How many selections one message may carry.
///
/// Enough to say "these three places disagree", short of a message that is
/// nothing but quotes.
const int maxChatSnippets = 8;

/// A run of text the user picked out of a file, on its way to the composer.
@immutable
class ChatSnippet {
  const ChatSnippet({
    required this.path,
    required this.text,
    required this.truncated,
  });

  /// The file it came out of — what tells the assistant *where* to look, and
  /// the only thing the chip can name a selection by.
  final String path;

  final String text;

  /// The selection ran past [kSnippetBudget] and was cut.
  final bool truncated;

  /// The file's own name, for the preview.
  String get name => path.split(RegExp(r'[/\\]')).last;

  @override
  bool operator ==(Object other) =>
      other is ChatSnippet && other.path == path && other.text == text;

  @override
  int get hashCode => Object.hash(path, text);
}

/// Trims [text] and caps it, or null when there is nothing worth sending.
///
/// Whitespace-only selections happen constantly — a stray drag across a blank
/// line — and a chip for one would be a chip for nothing.
ChatSnippet? snippetOf({required String path, required String text}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= kSnippetBudget) {
    return ChatSnippet(path: path, text: trimmed, truncated: false);
  }
  return ChatSnippet(
    path: path,
    text: trimmed.substring(0, kSnippetBudget),
    truncated: true,
  );
}

/// Selections a panel has handed to the composer, waiting to be taken.
///
/// A queue rather than the single value `composerPrefillProvider` holds: two
/// "Add to chat" clicks in quick succession are two selections the user meant
/// to keep, and the second must not land on the first.
final composerSnippetProvider =
    NotifierProvider<ComposerSnippets, List<ChatSnippet>>(ComposerSnippets.new);

class ComposerSnippets extends Notifier<List<ChatSnippet>> {
  @override
  List<ChatSnippet> build() => const [];

  void offer(ChatSnippet snippet) => state = [...state, snippet];

  /// The composer has them — forget them, so they aren't offered twice.
  void taken() => state = const [];
}

/// How the selections are put to the model: each quoted under the file it came
/// from, after whatever the user typed.
///
/// Folded into the message text rather than carried beside it, because that is
/// what makes the transcript honest — the user's turn shows exactly what was
/// asked, quotes and all, instead of a bubble that reads as a question about
/// nothing.
String messageWithSnippets(String message, List<ChatSnippet> snippets) {
  if (snippets.isEmpty) return message;
  final blocks = [
    for (final snippet in snippets)
      'From ${snippet.path}:\n```\n${snippet.text}\n```'
          '${snippet.truncated ? '\n[selection cut short here]' : ''}',
  ];
  return message.isEmpty
      ? blocks.join('\n\n')
      : '$message\n\n${blocks.join('\n\n')}';
}
