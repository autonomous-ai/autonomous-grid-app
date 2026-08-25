import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'terminal_ime.dart';

/// The terminal's text input, taken off `xterm` so an input method can rewrite
/// what it has already typed.
///
/// **This is what makes Vietnamese work**, and it is two halves that only work
/// together. `TerminalView(hardwareKeyboardOnly: true)` gives up the platform
/// text connection, which this holds instead: every change to the field is
/// diffed against what the program was last told, and the difference goes out as
/// rub-outs and a new tail ([terminalEdit]). But xterm in that mode still
/// *inserts printable characters itself* and answers `handled`, and on macOS a
/// key the framework claims is never offered to the input method at all — so
/// Telex never ran and the letters arrived raw. So the key handler passed to
/// [builder] declines them ([terminalKeyLane]), and lets everything that is not
/// text through to xterm untouched.
///
/// **The rest of the keyboard is still xterm's**, and deliberately: Enter,
/// Escape, Tab, the arrows and every `ctrl`-chord reach the program through
/// `TerminalView`'s own handler, which knows the escape sequences each of them
/// means on the buffer the program is using. Nothing here competes for them.
///
/// **The mirror never runs ahead of the platform.** An earlier version cleared
/// the field itself at every space — `setEditingState('')` plus a local
/// `_sent = ''` — and that races: the clear crosses a channel, so a keystroke
/// arriving before it lands is reported against the *old* text and diffed
/// against the new baseline, which re-sends the whole line. Typing `ls -la`
/// quickly put `ls ls -la` on the prompt and then rubbed out four characters
/// that were still in use. So [_sent] is only ever assigned what the platform
/// just said, the field is left to grow for as long as the terminal holds
/// focus, and nothing here writes to it except on attach and detach.
class ImeTerminalInput extends StatefulWidget {
  const ImeTerminalInput({
    super.key,
    required this.focusNode,
    required this.onInput,
    required this.builder,
  });

  /// The terminal's own focus — the same node the view is given. The connection
  /// follows it, so a terminal nobody is looking at holds no keyboard.
  final FocusNode focusNode;

  /// What to send the program — already text, ready for the pty.
  final ValueChanged<String> onInput;

  /// Builds the terminal, handing it the key handler it must call *first*
  /// (`TerminalView.onKeyEvent`). Passing it any other way would leave xterm
  /// swallowing the letters before this ever sees them.
  final Widget Function(
    BuildContext context,
    FocusOnKeyEventCallback onKeyEvent,
  )
  builder;

  @override
  State<ImeTerminalInput> createState() => _ImeTerminalInputState();
}

class _ImeTerminalInputState extends State<ImeTerminalInput>
    implements TextInputClient {
  TextInputConnection? _connection;

  /// What the program has already been told. The diff is against this, never
  /// against the field's own history.
  String _sent = '';

  /// Whether the platform is holding preedit text — a candidate window is up
  /// and the user has not chosen yet.
  ///
  /// Never true for Vietnamese, which composes by replacing what it already
  /// committed; true for Japanese, Chinese and Korean, where the whole keyboard
  /// belongs to the input method until it commits.
  bool _composing = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
    if (widget.focusNode.hasFocus) _attach();
  }

  @override
  void didUpdateWidget(ImeTerminalInput old) {
    super.didUpdateWidget(old);
    if (old.focusNode == widget.focusNode) return;
    old.focusNode.removeListener(_onFocusChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    _detach();
    super.dispose();
  }

  void _onFocusChanged() => widget.focusNode.hasFocus ? _attach() : _detach();

  void _attach() {
    if (_connection != null) return;
    // Autocorrect and suggestions off: this is a command line. Multiline so the
    // platform doesn't turn the Return key into a "done" action before the
    // terminal's own key handler has seen it.
    final connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _connection = connection;
    _sent = '';
    _composing = false;
    connection.setEditingState(_empty);
    connection.show();
  }

  void _detach() {
    _connection?.close();
    _connection = null;
    _sent = '';
    _composing = false;
  }

  /// Drops the last character from the field, because `xterm` is about to send
  /// the program the rub-out for it.
  ///
  /// The field has to follow or the input method keeps rewriting a letter the
  /// program no longer has: backspace in the middle of `chà`, then a tone key,
  /// and the diff would rub out a letter that had already gone.
  ///
  /// Counted in graphemes, for the same reason [terminalEdit] counts them:
  /// one press is one letter, and `ẻ` can be two code points.
  void _rubOut() {
    final connection = _connection;
    if (connection == null || _sent.isEmpty) return;
    final kept = _sent.characters.skipLast(1).toString();
    _sent = kept;
    connection.setEditingState(
      TextEditingValue(
        text: kept,
        selection: TextSelection.collapsed(offset: kept.length),
      ),
    );
  }

  /// Called by `TerminalView` before it does anything of its own with the key.
  ///
  /// [KeyEventResult.skipRemainingHandlers] rather than `handled` is the point:
  /// it stops xterm and every ancestor, and still leaves the framework telling
  /// the engine that nobody handled the key — which is the only thing that gets
  /// it to the input method.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Nothing is holding the keyboard yet, so declining would drop the key on
    // the floor. Better xterm's own insertion than silence.
    if (_connection == null) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    final lane = terminalKeyLane(
      key: event.logicalKey,
      character: event.character,
      modified:
          keyboard.isControlPressed ||
          keyboard.isMetaPressed ||
          keyboard.isAltPressed,
      composing: _composing,
    );
    if (lane == TerminalKeyLane.input) {
      return KeyEventResult.skipRemainingHandlers;
    }
    // `xterm` is about to spell this key for the program. Backspace is the one
    // it spells that also changes the line the field is mirroring, so the field
    // follows it down; everything else leaves the line alone or ends the word.
    if (event.logicalKey == LogicalKeyboardKey.backspace) _rubOut();
    return KeyEventResult.ignored;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (_connection == null) return;
    // Preedit is sent as it changes, not held back until the input method
    // commits — **because nothing else here would draw it.** `xterm` renders
    // marked text itself, underlined, but only through the text input this
    // widget took off it (`hardwareKeyboardOnly`), so held-back preedit is
    // simply invisible: the user typed a Vietnamese word, watched nothing
    // happen, and got the whole thing at once when the mark landed. Sending it
    // costs nothing, because a rewrite is what [terminalEdit] is for — the
    // commit arrives as one more edit and corrects whatever the preedit put
    // there.
    //
    // The flag still matters for the *keyboard*: while a candidate window is
    // up, Enter commits the word instead of running the line
    // ([terminalKeyLane]).
    _composing = value.composing.isValid && !value.composing.isCollapsed;
    final edit = terminalEdit(_sent, value.text);
    _sent = value.text;
    if (edit.isEmpty) return;
    widget.onInput(edit);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _onKeyEvent);

  // — the rest of TextInputClient, none of which a terminal has an answer for —

  @override
  void connectionClosed() => _connection = null;

  @override
  TextEditingValue? get currentTextEditingValue => TextEditingValue(
    text: _sent,
    selection: TextSelection.collapsed(offset: _sent.length),
  );

  @override
  AutofillScope? get currentAutofillScope => null;

  /// Enter reaches the program through `TerminalView`'s key handler, which
  /// knows whether the program wants `\r` or `\r\n`. Acting here as well would
  /// send it twice.
  @override
  void performAction(TextInputAction action) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  /// The terminal takes focus through its own `FocusNode`; nothing here needs
  /// to claim it, and answering true would fight that node for it.
  @override
  bool onFocusReceived() => false;
}

/// An empty field with the caret *in* it. `TextEditingValue.empty` carries an
/// invalid selection (offset `-1`), which the platform reads as no caret at all.
const _empty = TextEditingValue(selection: TextSelection.collapsed(offset: 0));
