import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wires a composer field to the desktop chat conventions: Enter sends,
/// Shift+Enter drops to a new line, and ⌘V / Ctrl+V pastes whatever is on the
/// clipboard — not just the part of it that happens to be text.
///
/// It owns a [FocusNode] whose key handler runs before the field acts on the
/// keystroke, which is the only place both can be caught: plain Enter is
/// swallowed (turned into a send) while Shift+Enter falls through to the field's
/// own newline, and paste is taken over before the editor inserts text so a
/// screenshot can become an attachment instead of nothing at all. Hand the node
/// to your [TextField] via [builder]; the field must allow newlines
/// (`maxLines > 1`) for Shift+Enter to add one. [onSend] fires only when
/// [canSend] is true, so a blocked turn eats the Enter rather than sending
/// nothing or leaving a stray line break.
class ComposerKeys extends StatefulWidget {
  const ComposerKeys({
    super.key,
    required this.canSend,
    required this.onSend,
    required this.builder,
    this.onPaste,
  });

  final bool canSend;
  final VoidCallback onSend;

  /// Takes over ⌘V / Ctrl+V — it is handed everything on the clipboard,
  /// including the plain text the field would otherwise have inserted itself.
  /// Null leaves paste to the field, which is right for a plain text box.
  final VoidCallback? onPaste;

  final Widget Function(BuildContext context, FocusNode focusNode) builder;

  @override
  State<ComposerKeys> createState() => _ComposerKeysState();
}

class _ComposerKeysState extends State<ComposerKeys> {
  late final FocusNode _node = FocusNode(onKeyEvent: _onKeyEvent);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_isPaste(event)) {
      widget.onPaste!();
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    // Shift+Enter is the "new line" gesture — let the field insert it.
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (widget.canSend) widget.onSend();
    // Swallow the plain Enter either way, so a turn that can't send doesn't drop
    // an unwanted line break where the user expected the message to go out.
    return KeyEventResult.handled;
  }

  /// The platform's paste chord — ⌘V on a Mac, Ctrl+V elsewhere. Asked of the
  /// platform rather than accepting either, so Ctrl+V on macOS (which is not
  /// paste, and is a text-editing chord of its own) keeps its own meaning.
  bool _isPaste(KeyEvent event) {
    if (widget.onPaste == null) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isShiftPressed) return false;
    return defaultTargetPlatform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _node);
}
