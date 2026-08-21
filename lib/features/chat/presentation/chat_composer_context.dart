part of 'chat_composer.dart';

/// What's riding on this message, above the box you type in: pictures as
/// thumbnails, documents and terminals as chips.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.files,
    required this.snippets,
    required this.terminals,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
    required this.onRemoveFileAt,
    required this.onRemoveSnippets,
    required this.onRemoveTerminal,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final List<ChatFile> files;
  final List<ChatSnippet> snippets;
  final List<AttachedTerminal> terminals;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;
  final ValueChanged<int> onRemoveFileAt;
  final VoidCallback onRemoveSnippets;
  final ValueChanged<String> onRemoveTerminal;

  @override
  Widget build(BuildContext context) {
    final empty =
        attachments.isEmpty &&
        files.isEmpty &&
        snippets.isEmpty &&
        terminals.isEmpty;
    if (isText && empty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The media modes keep a bar of their own, because theirs is a place
          // to *pick* images: it carries the add tile and the line saying why an
          // image is needed, and neither belongs in a row of things already
          // attached.
          if (!isText) ...[
            AttachmentBar(
              attachments: attachments,
              maxCount: needsImage ? 1 : 3,
              hint: _attachmentHint(),
              onAdd: onAdd,
              onRemoveAt: onRemoveAt,
            ),
            if (files.isNotEmpty || snippets.isNotEmpty || terminals.isNotEmpty)
              const SizedBox(height: 8),
          ],
          _ContextRow(
            // Already shown above in the media modes' own bar.
            attachments: isText ? attachments : const [],
            files: files,
            snippets: snippets,
            terminals: terminals,
            onRemoveAt: onRemoveAt,
            onRemoveFileAt: onRemoveFileAt,
            onRemoveSnippets: onRemoveSnippets,
            onRemoveTerminal: onRemoveTerminal,
          ),
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

/// Everything riding on this message, on one line: pictures, then documents,
/// then selections, then terminals.
///
/// One row rather than a strip each. They are one idea to the reader — what
/// goes with this message — and three strips pushed the box you type in a row
/// further down the screen for every kind of thing attached.
///
/// The order is the old stacking order read left to right, and it still says the
/// same thing: a picture and a document were chosen deliberately, a terminal is
/// merely open, so the deliberate things come first.
class _ContextRow extends StatelessWidget {
  const _ContextRow({
    required this.attachments,
    required this.files,
    required this.snippets,
    required this.terminals,
    required this.onRemoveAt,
    required this.onRemoveFileAt,
    required this.onRemoveSnippets,
    required this.onRemoveTerminal,
  });

  final List<MediaAttachment> attachments;
  final List<ChatFile> files;
  final List<ChatSnippet> snippets;
  final List<AttachedTerminal> terminals;
  final ValueChanged<int> onRemoveAt;
  final ValueChanged<int> onRemoveFileAt;
  final VoidCallback onRemoveSnippets;
  final ValueChanged<String> onRemoveTerminal;

  /// A thumbnail in here is a receipt, not a picture to study — smaller than the
  /// media bar's, so a row that mixes one with a chip reads as a row rather than
  /// as a picture with some chips stuck to it.
  static const _thumbSize = 44.0;

  /// How tall this row may grow before it scrolls: three runs of thumbnails.
  ///
  /// A message carries as many pictures as the wire holds rather than four, so
  /// a folder of screenshots dropped at once would otherwise push the box you
  /// type in off the bottom of the window.
  static const _maxHeight = _thumbSize * 3 + 8 * 2;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty &&
        files.isEmpty &&
        snippets.isEmpty &&
        terminals.isEmpty) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _maxHeight),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          // Centred across, not baseline-aligned: a thumbnail is taller than a chip,
          // and mixed heights hung from a common top edge read as something having
          // gone wrong rather than as two kinds of thing side by side.
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < attachments.length; i++)
              AttachmentThumb(
                attachment: attachments[i],
                size: _thumbSize,
                onRemove: () => onRemoveAt(i),
              ),
            // Each file its own child of *this* wrap rather than a [FileChips] block
            // inside it: nested, a run of eight documents would wrap as one lump and
            // leave a hole beside the thumbnails.
            for (var i = 0; i < files.length; i++)
              FileChip(file: files[i], onRemove: () => onRemoveFileAt(i)),
            if (snippets.isNotEmpty)
              SnippetChip(snippets: snippets, onRemove: onRemoveSnippets),
            for (final terminal in terminals)
              ContextChip(
                label: terminal.label,
                // Says what will be sent, because that is what decides whether the
                // chip is worth leaving on: the whole screen, not just the last
                // command, and only the end of it on a long build.
                tooltip:
                    'What this terminal is showing goes with your message — its '
                    'last $kTerminalCaptureLines lines at most.',
                onRemove: () => onRemoveTerminal(terminal.tabId),
              ),
          ],
        ),
      ),
    );
  }
}
