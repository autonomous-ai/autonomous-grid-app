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
  final int maxCount;

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
    final full = attachments.length >= maxCount;
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
              _Thumb(
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
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.attachment,
    required this.size,
    required this.onRemove,
  });

  final MediaAttachment attachment;
  final double size;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
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
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: BoxDecoration(
                color: AppPalette.windowBg,
                shape: BoxShape.circle,
                border: Border.all(color: AppPalette.divider),
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close_rounded, size: 14),
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
