part of 'chat_composer.dart';

/// What's riding on this message, above the box you type in: pictures as
/// thumbnails, documents as chips.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.files,
    required this.snippets,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
    required this.onRemoveFileAt,
    required this.onRemoveSnippets,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final List<ChatFile> files;
  final List<ChatSnippet> snippets;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;
  final ValueChanged<int> onRemoveFileAt;
  final VoidCallback onRemoveSnippets;

  @override
  Widget build(BuildContext context) {
    final empty = attachments.isEmpty && files.isEmpty && snippets.isEmpty;
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
          // Documents and selections share a row: they are the same kind of
          // thing to the reader — "what is riding on this message" — and two
          // rows for two chips would push the box you type in down the screen.
          if (files.isNotEmpty || snippets.isNotEmpty) ...[
            if (attachments.isNotEmpty) const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (files.isNotEmpty)
                  FileChips(files: files, onRemoveAt: onRemoveFileAt),
                if (snippets.isNotEmpty)
                  SnippetChip(snippets: snippets, onRemove: onRemoveSnippets),
              ],
            ),
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
