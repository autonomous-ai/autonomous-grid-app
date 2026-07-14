part of 'chat_composer.dart';

class _ContextStrip extends StatelessWidget {
  const _ContextStrip({required this.gridName});

  final String gridName;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppPalette.cardBg,
        border: Border(bottom: BorderSide(color: AppGlass.hair)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Row(
          children: [
            const Icon(
              Icons.folder_outlined,
              size: 16,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(child: _StripLabel(label: gridName)),
            const SizedBox(width: 14),
            const Icon(
              Icons.hub_outlined,
              size: 15,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 6),
            const _StripLabel(label: 'Local'),
          ],
        ),
      ),
    );
  }
}

class _StripLabel extends StatelessWidget {
  const _StripLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;

  @override
  Widget build(BuildContext context) {
    if (isText && attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: AttachmentBar(
        attachments: attachments,
        maxCount: isText ? maxChatImages : (needsImage ? 1 : 3),
        showAddTile: !isText,
        hint: _attachmentHint(),
        onAdd: onAdd,
        onRemoveAt: onRemoveAt,
      ),
    );
  }

  String? _attachmentHint() {
    if (isText) return null;
    if (needsImage) return 'Video needs a starting image to animate.';
    return 'Optional: attach up to 3 images to edit instead of generate.';
  }
}
