import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_file.dart';

/// The documents on a message, as a row of chips.
///
/// One widget for both places a file is shown — waiting in the composer, where
/// it can still be taken off, and sent in the transcript, where it can be opened
/// — so the two never drift into looking like different things.
class FileChips extends StatelessWidget {
  const FileChips({super.key, required this.files, this.onRemoveAt});

  final List<ChatFile> files;

  /// Removes the file at an index. Null in the transcript: a message that has
  /// been sent can't un-attach anything.
  final ValueChanged<int>? onRemoveAt;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < files.length; i++)
          FileChip(
            file: files[i],
            onRemove: onRemoveAt == null ? null : () => onRemoveAt!(i),
          ),
      ],
    );
  }
}

/// One attached document: what it is, how big, and — when the app couldn't read
/// its text — that the assistant will have to open it itself.
class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.file, this.onRemove});

  final ChatFile file;
  final VoidCallback? onRemove;

  /// Opens the file in whatever app owns it. The chip names a real file on this
  /// machine, so the obvious thing to do with it should work.
  Future<void> _open() => launchUrl(Uri.file(file.path));

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips
    final radius = BorderRadius.circular(10);
    // The tooltip carries the path and what will actually be sent — the two
    // things the chip has no room for, and the second is what decides whether
    // the answer can be trusted.
    return Tooltip(
      message: file.isReadable
          ? '${file.path}\nIts text will be sent with your message.'
          : "${file.path}\nThe app couldn't read this one — the assistant will "
                'be given the file to open.',
      child: Material(
        color: AppPalette.cardBg,
        borderRadius: radius,
        child: InkWell(
          onTap: _open,
          borderRadius: radius,
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppSurface.hoverFill,
          child: Container(
            padding: EdgeInsets.fromLTRB(10, 7, onRemove == null ? 10 : 4, 7),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: AppPalette.divider),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _iconFor(file.name),
                  size: 16,
                  color: file.isReadable
                      ? AppPalette.textSecondary
                      : AppPalette.warn,
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: AppFont.medium,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  formatFileSize(file.sizeBytes),
                  style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
                ),
                if (onRemove != null) _RemoveButton(onTap: onRemove!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The glyph for a file type — the shapes people already sort documents by, so
/// a spreadsheet is findable in a row of chips without reading the names.
IconData _iconFor(String name) => switch (fileExtensionOf(name)) {
  'pdf' => Icons.picture_as_pdf_outlined,
  'xlsx' || 'xls' || 'csv' || 'tsv' => Icons.table_chart_outlined,
  'pptx' || 'ppt' => Icons.slideshow_outlined,
  'docx' || 'doc' || 'rtf' || 'txt' || 'md' => Icons.description_outlined,
  _ => Icons.insert_drive_file_outlined,
};

/// Takes one file back off the message.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(7);
    return Tooltip(
      message: 'Remove',
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        splashFactory: NoSplash.splashFactory,
        hoverColor: AppSurface.hoverFill,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: 14,
            color: AppPalette.textFaint,
            semanticLabel: 'Remove file',
          ),
        ),
      ),
    );
  }
}
