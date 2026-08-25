import 'package:flutter/widgets.dart';

/// The byte a terminal reads as "rub out the character before the cursor".
///
/// `\x7f` (DEL), not `\b`: it is what a terminal sends for Backspace, and what
/// an agent's TUI is listening for.
const String kTerminalDelete = '\x7f';

/// What to send a program to turn what it has already been told ([previous])
/// into what the user now means ([next]).
///
/// **This exists because Vietnamese Telex rewrites what it has already typed.**
/// Typing `e` then `r` is not two characters — it is `e`, then a *replacement*
/// of that `e` with `ẻ`. macOS delivers that as an edit to the field, with no
/// composition around it, and `xterm 4.0.0` cannot express it: its text input
/// only ever appends the tail past what it last saw
/// (`text.substring(_initEditingState.text.length)`), so the `e` is already
/// down the pty and unrecallable, and the user gets `eẻ`.
///
/// So the edit is worked out as a diff instead: back over what changed, then
/// type what it became. Ported from the same fix in the Autonomous desktop app's
/// `ime_input.js`, which met this on the web side of the same problem.
///
/// **Deletions are counted in graphemes, not code units.** One `\x7f` erases
/// one character as the user sees it, and `ẻ` can be two code points; counting
/// units would send two rub-outs for one letter and eat the one before it.
///
/// Newlines are never emitted. Enter reaches the program through the key path,
/// which owns it — see [ImeTerminalInput], which resets its baseline on one
/// rather than diffing it and sending a second.
String terminalEdit(String previous, String next) {
  if (previous == next) return '';
  final prefix = _sharedPrefix(previous, next);
  final removed = previous.substring(prefix).characters.length;
  final added = next.substring(prefix).replaceAll(RegExp(r'[\r\n]'), '');
  return kTerminalDelete * removed + added;
}

/// How many code units [a] and [b] open with in common, never splitting a
/// surrogate pair.
///
/// Cutting between the halves of a pair would leave half a character on each
/// side of the diff, and the tail would be typed as a replacement character.
int _sharedPrefix(String a, String b) {
  final limit = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  if (i > 0 && i < a.length && i < b.length && _isHighSurrogate(a, i - 1)) {
    i--;
  }
  return i;
}

bool _isHighSurrogate(String text, int index) {
  final unit = text.codeUnitAt(index);
  return unit >= 0xD800 && unit <= 0xDBFF;
}

/// Whether the mirror should be emptied and started again after [text].
///
/// An IME needs the word it is still working on to be there to rewrite; it has
/// no use for the sentence before it. Cutting at a space keeps exactly that
/// much, so the hidden field cannot grow for the life of a session and a stale
/// edit cannot reach back across a word boundary.
bool endsRun(String text) =>
    text.isNotEmpty && RegExp(r'[\s\r\n]$').hasMatch(text);
