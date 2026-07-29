import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wires a composer field to the desktop chat convention: Enter sends, and
/// Shift+Enter drops to a new line.
///
/// It owns a [FocusNode] whose key handler runs before the field inserts text,
/// so plain Enter can be swallowed (turned into a send) while Shift+Enter falls
/// through to the field's own newline. Hand the node to your [TextField] via
/// [builder]; the field must allow newlines (`maxLines > 1`) for Shift+Enter to
/// add one. [onSend] fires only when [canSend] is true, so a blocked turn eats
/// the Enter rather than sending nothing or leaving a stray line break.
class SendOnEnter extends StatefulWidget {
  const SendOnEnter({
    super.key,
    required this.canSend,
    required this.onSend,
    required this.builder,
  });

  final bool canSend;
  final VoidCallback onSend;
  final Widget Function(BuildContext context, FocusNode focusNode) builder;

  @override
  State<SendOnEnter> createState() => _SendOnEnterState();
}

class _SendOnEnterState extends State<SendOnEnter> {
  late final FocusNode _node = FocusNode(onKeyEvent: _onKeyEvent);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (event is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
    // Shift+Enter is the "new line" gesture — let the field insert it.
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (widget.canSend) widget.onSend();
    // Swallow the plain Enter either way, so a turn that can't send doesn't drop
    // an unwanted line break where the user expected the message to go out.
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _node);
}
