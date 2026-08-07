part of 'chat_composer.dart';

/// What's riding on this message, above the box you type in: pictures as
/// thumbnails, documents and terminals as chips.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.files,
    required this.terminals,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
    required this.onRemoveFileAt,
    required this.onRemoveTerminal,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final List<ChatFile> files;
  final List<AttachedTerminal> terminals;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;
  final ValueChanged<int> onRemoveFileAt;
  final ValueChanged<String> onRemoveTerminal;

  @override
  Widget build(BuildContext context) {
    final empty = attachments.isEmpty && files.isEmpty && terminals.isEmpty;
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
          // Last, nearest the box: a file was picked deliberately, a terminal is
          // merely open, and the row closest to the sentence is the one people
          // read on the way to pressing Send.
          if (terminals.isNotEmpty) ...[
            if (attachments.isNotEmpty || files.isNotEmpty)
              const SizedBox(height: 8),
            _TerminalChips(terminals: terminals, onRemove: onRemoveTerminal),
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

/// The terminals this message will carry, as a row of chips.
class _TerminalChips extends StatelessWidget {
  const _TerminalChips({required this.terminals, required this.onRemove});

  final List<AttachedTerminal> terminals;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final terminal in terminals)
        ContextChip(
          label: terminal.label,
          // Says what will be sent, because that is what decides whether the
          // chip is worth leaving on: the whole screen, not just the last
          // command, and only the end of it on a long build.
          tooltip:
              'What this terminal is showing goes with your message — its '
              'last $kTerminalCaptureLines lines at most.',
          onRemove: () => onRemove(terminal.tabId),
        ),
    ],
  );
}
