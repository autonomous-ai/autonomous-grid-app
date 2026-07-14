part of 'chat_composer.dart';

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.approvalPicker,
    required this.modelPicker,
    required this.onPickImage,
    required this.onSend,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;

  /// What the assistant may do to this computer — null when nothing on this turn
  /// can touch it (a picture goes to the grid, which has no filesystem), so the
  /// control isn't offered where it would mean nothing.
  final Widget? approvalPicker;
  final Widget modelPicker;
  final VoidCallback onPickImage;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Row(
        children: [
          _AttachButton(canAttach: canAttach, onPickImage: onPickImage),
          const SizedBox(width: 4),
          if (approvalPicker != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 178),
              child: approvalPicker!,
            ),
          const Expanded(child: SizedBox()),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 140, height: 30, child: modelPicker),
              const SizedBox(width: 8),
              _SendButton(sending: sending, canSend: canSend, onSend: onSend),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.canAttach, required this.onPickImage});

  final bool canAttach;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: canAttach ? 'Attach image' : 'Up to $maxChatImages images',
        iconSize: 19,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        icon: const Icon(Icons.add_rounded),
        onPressed: canAttach ? onPickImage : null,
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.canSend,
    required this.onSend,
  });

  final bool sending;
  final bool canSend;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: FilledButton(
        onPressed: canSend ? onSend : null,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          backgroundColor: AppPalette.textPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF9B9B9B),
          disabledForegroundColor: AppPalette.textFaint,
        ),
        child: sending
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(
                Icons.arrow_upward_rounded,
                size: 17,
                semanticLabel: 'Send',
              ),
      ),
    );
  }
}
