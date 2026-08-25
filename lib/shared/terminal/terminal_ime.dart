import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The byte a terminal reads as "rub out the character before the cursor".
///
/// `\x7f` (DEL), not `\b`: it is what a terminal sends for Backspace, and what
/// an agent's TUI is listening for.
const String kTerminalDelete = '\x7f';

/// Which of the two keyboards a key belongs to.
///
/// A terminal needs both. Most keys are escape sequences that only the emulator
/// knows how to spell, and text is text — but on macOS a key can only go to one
/// of them, because the platform hands a key to the input method *only* when the
/// framework says nobody handled it.
enum TerminalKeyLane {
  /// `xterm`'s own key handler, which turns the key into whatever the program
  /// on the other end expects to read for it.
  terminal,

  /// The platform text input, so an input method gets to compose before
  /// anything is sent — see [terminalEdit].
  input,
}

/// Where [key] should be sent.
///
/// **This is the whole Vietnamese fix**, and it is a routing decision rather
/// than an encoding one. `xterm 4.0.0` in `hardwareKeyboardOnly` mode inserts
/// `event.character` itself and answers `handled`, so macOS never offers the
/// key to the input method and Telex never runs at all. Every printable key has
/// to be declined here instead, and the letters arrive later as an edit to the
/// field.
///
/// Everything that is not plain text stays with the terminal, because that is
/// where the knowledge is: Enter, Tab, Escape, the arrows, the function keys and
/// every `ctrl`/`alt`/`⌘` chord spell differently depending on the buffer the
/// program is using, and the input method has no use for any of them.
///
/// **Backspace is the program's**, unless an input method is mid-composition.
///
/// It used to go to the field whenever the field held anything, so the two would
/// agree on the line. They don't: macOS does not edit the field for a client
/// that isn't `EditableText`. It sends the key on as the selector
/// `deleteBackward:` and expects the client to act — which is why
/// [ImeTerminalInput] now answers those too — and until it did, every Backspace
/// typed after a letter simply vanished.
///
/// It matters most for the input methods that don't compose at all. EVKey,
/// which is what Vietnamese is usually typed with here, corrects a word by
/// *sending Backspace itself* and then the replacement letter: type `cuar` and
/// it rubs out `r` and types `ủ`. Swallow that Backspace and the correction
/// lands beside the mistake instead of over it — `cuaủa` where the user meant
/// `của`, which is exactly what the screen showed.
///
/// While a candidate window is up the key still belongs to the input method:
/// that case is settled by [composing] above, before this.
///
/// [composing] is the other whole-keyboard case, and it is the one Vietnamese
/// never reaches: Telex is *modeless* — it commits each letter and then
/// replaces it — while Japanese, Chinese and Korean put up a candidate window
/// first. Nothing may be sent to the program until the user has chosen.
TerminalKeyLane terminalKeyLane({
  required LogicalKeyboardKey key,
  required String? character,
  required bool modified,
  required bool composing,
}) {
  if (modified) return TerminalKeyLane.terminal;
  // While an input method is showing candidates, every key belongs to it:
  // Enter commits the choice, Escape abandons it, space and the digits pick
  // between them and the arrows walk the list. Handing any of those to the
  // program as well would run a command the user was only choosing a word
  // with.
  if (composing) return TerminalKeyLane.input;
  if (key == LogicalKeyboardKey.backspace) return TerminalKeyLane.terminal;
  if (character == null || character.isEmpty) return TerminalKeyLane.terminal;
  // Enter arrives carrying `\r`, Tab `\t`, Escape `\x1b`. They are keys, not
  // text, and the terminal spells them.
  if (LogicalKeyboardKey.isControlCharacter(character)) {
    return TerminalKeyLane.terminal;
  }
  return TerminalKeyLane.input;
}

/// Whether [key] is only a modifier being held.
///
/// It sends nothing on its own, so it must not be read as the user having moved
/// on from the word the input method is still composing — holding Shift for a
/// capital in the middle of a Vietnamese word would otherwise end the run and
/// strand the letters already sent.
bool isModifierKey(LogicalKeyboardKey key) => _modifiers.contains(key);

// Not `const`: `LogicalKeyboardKey` defines its own `==`, which a constant
// set is not allowed to rely on.
final Set<LogicalKeyboardKey> _modifiers = {
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.fn,
};

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
/// which owns it — see [terminalKeyLane].
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

/// What a macOS editing selector means to a terminal, or null for one it has no
/// answer for.
///
/// macOS delivers a key an input method didn't consume as a *selector* rather
/// than as text — `deleteBackward:` for Backspace, and the rest of the Emacs-ish
/// bindings a Cocoa text field answers. Flutter passes them to the text input
/// client and `EditableText` turns them into intents; a client that ignores them
/// (which this one did) loses the keystroke entirely.
///
/// Only the rub-outs are mapped. Movement selectors (`moveLeft:` and friends)
/// are deliberately absent: the caret they would move belongs to the program,
/// which draws its own line and is already sent those keys through xterm's
/// handler.
String? terminalSelectorInput(String selector) => switch (selector) {
  'deleteBackward:' => kTerminalDelete,
  // ^W and ^U, which is what a terminal line editor reads these as.
  'deleteWordBackward:' => '\x17',
  'deleteToBeginningOfLine:' => '\x15',
  'deleteForward:' => '\x1b[3~',
  _ => null,
};
