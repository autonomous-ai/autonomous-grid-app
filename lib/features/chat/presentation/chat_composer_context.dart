part of 'chat_composer.dart';

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
