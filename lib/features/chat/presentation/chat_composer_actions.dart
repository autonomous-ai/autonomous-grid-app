part of 'chat_composer.dart';

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.modelPicker,
    required this.onPickImage,
    required this.onSend,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;
  final Widget modelPicker;
  final VoidCallback onPickImage;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
      child: Row(
        children: [
          _AttachButton(canAttach: canAttach, onPickImage: onPickImage),
          const SizedBox(width: 4),
          const Expanded(child: _ApprovalHint()),
          const SizedBox(width: 12),
          SizedBox(width: 140, height: 32, child: modelPicker),
          const SizedBox(width: 8),
          _SendButton(sending: sending, canSend: canSend, onSend: onSend),
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
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: canAttach ? 'Attach image' : 'Up to $maxChatImages images',
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        icon: const Icon(Icons.add_rounded),
        onPressed: canAttach ? onPickImage : null,
      ),
    );
  }
}

class _ApprovalHint extends StatelessWidget {
  const _ApprovalHint();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.verified_user_outlined,
          size: 15,
          color: AppPalette.textFaint,
        ),
        SizedBox(width: 5),
        Flexible(
          child: Text(
            'Ask for approval',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
          ),
        ),
      ],
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
      width: 34,
      height: 34,
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
                size: 18,
                semanticLabel: 'Send',
              ),
      ),
    );
  }
}
