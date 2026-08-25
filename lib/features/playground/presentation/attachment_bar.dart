import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/playground_request.dart';

/// Opens the system image picker and returns the chosen file as a
/// [MediaAttachment], or null if the user cancelled. Shared by the media
/// [AttachmentBar] and the Chat composer's inline attach button.
Future<MediaAttachment?> pickImageAttachment() async {
  const group = XTypeGroup(label: 'Images', extensions: kImageExtensions);
  final file = await openFile(acceptedTypeGroups: const [group]);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return MediaAttachment(filename: file.name, bytes: bytes);
}

/// Lets the user attach source image(s) — for media requests that need them
/// (`image/edit` up to three, `i2v` exactly one) and for vision chat. Shows
/// thumbnails with a remove button and, unless [showAddTile] is false, an
/// "Add image" tile until [maxCount] is reached. Pure UI: the attachment list
/// is owned by the parent, mutated through the callbacks.
class AttachmentBar extends StatelessWidget {
  const AttachmentBar({
    super.key,
    required this.attachments,
    required this.maxCount,
    required this.onAdd,
    required this.onRemoveAt,
    this.hint,
    this.showAddTile = true,
  });

  final List<MediaAttachment> attachments;

  /// How many pictures this request takes, or null where nothing counts them —
  /// a vision chat is bounded by the bytes a request body holds, so the tile
  /// stays until the pictures themselves run the budget out.
  final int? maxCount;

  /// Optional one-line prompt telling the user why an image is needed (e.g.
  /// video needs a starting image). Omitted in the Chat composer, where the
  /// inline "+" already implies it.
  final String? hint;

  /// Whether to render the "Add image" tile. False when the caller supplies its
  /// own add affordance (the Chat composer's inline "+").
  final bool showAddTile;

  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;

  static const _thumbSize = 56.0;

  Future<void> _pick() async {
    final attachment = await pickImageAttachment();
    if (attachment != null) onAdd(attachment);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final limit = maxCount;
    final full = limit != null && attachments.length >= limit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hint != null) ...[
          Text(
            hint!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < attachments.length; i++)
              AttachmentThumb(
                attachment: attachments[i],
                size: _thumbSize,
                onRemove: () => onRemoveAt(i),
              ),
            if (!full && showAddTile) _AddTile(size: _thumbSize, onTap: _pick),
          ],
        ),
      ],
    );
  }
}

/// One attached image with a remove affordance.
///
/// The remove button sits *inside* the picture's own corner. Hanging off the
/// outside, as it did, made the tile 6px taller and wider than the size it was
/// given: nothing could line up beside it, and on the top row the button was cut
/// off by the padding above the strip.
class AttachmentThumb extends StatelessWidget {
  const AttachmentThumb({
    super.key,
    required this.attachment,
    required this.onRemove,
    this.size = 56,
  });

  final MediaAttachment attachment;

  /// The tile's side. Bigger where picking images is the job (the media bar),
  /// smaller in the chat composer, where a thumbnail is a receipt for something
  /// already attached rather than something to look at.
  final double size;

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            attachment.bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 3,
          right: 3,
          child: GestureDetector(
            onTap: onRemove,
            child: const DecoratedBox(
              // A fixed scrim rather than a theme token, and the one place in
              // the app that is right: this sits on a photograph, which can be
              // any colour in either theme, so the glyph needs its own ground
              // rather than the window's.
              decoration: BoxDecoration(
                color: Color(0xB3000000),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The dashed "add an image" tile.
class _AddTile extends StatelessWidget {
  const _AddTile({required this.size, required this.onTap});
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.divider),
        ),
        child: const Icon(Icons.add_photo_alternate_outlined, size: 22),
      ),
    );
  }
}
