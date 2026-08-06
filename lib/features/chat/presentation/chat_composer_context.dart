part of 'chat_composer.dart';

/// What's riding on this message, above the box you type in: pictures as
/// thumbnails, documents as chips.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.files,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
    required this.onRemoveFileAt,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final List<ChatFile> files;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;
  final ValueChanged<int> onRemoveFileAt;

  @override
  Widget build(BuildContext context) {
    final empty = attachments.isEmpty && files.isEmpty;
    if (isText && empty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isText || attachments.isNotEmpty)
            AttachmentBar(
              attachments: attachments,
              maxCount: isText ? maxChatImages : (needsImage ? 1 : 3),
              showAddTile: !isText,
              hint: _attachmentHint(),
              onAdd: onAdd,
              onRemoveAt: onRemoveAt,
            ),
          if (files.isNotEmpty) ...[
            if (attachments.isNotEmpty) const SizedBox(height: 8),
            FileChips(files: files, onRemoveAt: onRemoveFileAt),
          ],
        ],
      ),
    );
  }

  String? _attachmentHint() {
    if (isText) return null;
    if (needsImage) return 'Video needs a starting image to animate.';
    return 'Optional: attach up to 3 images to edit instead of generate.';
  }
}
