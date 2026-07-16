import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';

/// The message composer — a multiline field plus a circular send button that
/// spins while a request is in flight. [canSend] gates both Enter-to-send and
/// the button (e.g. a video needs an attached image first). Shared by the
/// Playground dialog and the Chat tab.
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.sending,
    required this.canSend,
    required this.hint,
    required this.onSend,
    this.prefix,
  });

  final TextEditingController controller;
  final bool sending;
  final bool canSend;
  final String hint;
  final VoidCallback onSend;

  /// Optional leading action inside the field (e.g. the Chat composer's "+"
  /// image-attach button). Null in the Playground, which attaches via its bar.
  final Widget? prefix;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 5,
            enabled: !sending,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) {
              if (canSend) onSend();
            },
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: AppPalette.cardBg,
              prefixIcon: prefix,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: _border(AppPalette.divider),
              enabledBorder: _border(AppPalette.divider),
              focusedBorder: _border(AppPalette.accent, width: 1.5),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 48,
          height: 48,
          child: FilledButton(
            onPressed: canSend ? onSend : null,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: sending
                ? const AppSpinner(size: SpinnerSize.large)
                : const Icon(Icons.arrow_upward_rounded, size: 20),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
}
