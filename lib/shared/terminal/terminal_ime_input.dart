import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'terminal_ime.dart';

/// The terminal's text input, taken off `xterm` so an input method can rewrite
/// what it has already typed.
///
/// **This is what makes Vietnamese work.** `xterm 4.0.0` owns the platform text
/// connection itself and can only ever append what it has not seen yet, so a
/// Telex `e` → `ẻ` arrives as an extra character rather than a replacement and
/// the user reads `eẻ`. `TerminalView(hardwareKeyboardOnly: true)` hands that
/// connection back, and this holds it instead: every change to the field is
/// diffed against what the program was last told, and the difference goes out as
/// rub-outs and a new tail ([terminalEdit]).
///
/// **The keyboard is still `xterm`'s**, and deliberately: Enter, Escape, Tab,
/// the arrows and every `ctrl`-chord reach the program through
/// `TerminalView`'s own key handler, which knows the escape sequences each of
/// them means on the buffer the program is using. Nothing here competes for
/// them — a plain letter is the only thing that handler declines (it answers
/// only for `ctrl`/`alt` chords), which is exactly the gap this fills.
///
/// The one place the two meet is Enter: the key handler sends the carriage
/// return, and the newline the platform also puts in the field would be a
/// second one. So a run ends at whitespace ([endsRun]) — the baseline is
/// cleared and the newline is never diffed. That is also what keeps the hidden
/// field from growing for the life of a session, while leaving the word the IME
/// is still working on in place for it to rewrite.
class ImeTerminalInput extends StatefulWidget {
  const ImeTerminalInput({
    super.key,
    required this.focusNode,
    required this.onInput,
    required this.child,
  });

  /// The terminal's own focus. The connection follows it, so a terminal nobody
  /// is looking at holds no keyboard.
  final FocusNode focusNode;

  /// What to send the program — already escapes and text, ready for the pty.
  final ValueChanged<String> onInput;

  final Widget child;

  @override
  State<ImeTerminalInput> createState() => _ImeTerminalInputState();
}

class _ImeTerminalInputState extends State<ImeTerminalInput>
    implements TextInputClient {
  TextInputConnection? _connection;

  /// What the program has already been told. The diff is against this, never
  /// against the field's own history.
  String _sent = '';

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
    _reset(connection);
    connection.show();
  }

  void _detach() {
    _connection?.close();
    _connection = null;
    _sent = '';
  }

  /// Start a fresh run: an empty field, and nothing owed to the program.
  void _reset(TextInputConnection connection) {
    _sent = '';
    connection.setEditingState(TextEditingValue.empty);
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final connection = _connection;
    if (connection == null) return;
    final edit = terminalEdit(_sent, value.text);
    _sent = value.text;
    if (edit.isNotEmpty) widget.onInput(edit);
    // Ended on whitespace — including the newline Enter leaves behind, which
    // the key handler has already sent as a carriage return.
    if (endsRun(value.text)) _reset(connection);
  }

  @override
  Widget build(BuildContext context) => widget.child;

  // — the rest of TextInputClient, none of which a terminal has an answer for —

  @override
  void connectionClosed() => _connection = null;

  @override
  TextEditingValue? get currentTextEditingValue =>
      TextEditingValue(text: _sent);

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
