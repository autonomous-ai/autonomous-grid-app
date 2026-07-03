import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/playground_request.dart';

/// Lets the user attach source image(s) for media requests that need them —
/// `image/edit` (up to three) and `i2v` (exactly one). Shows thumbnails with a
/// remove button and an "Add image" tile until [maxCount] is reached. Pure UI:
/// the attachment list is owned by the parent, mutated through the callbacks.
class AttachmentBar extends StatelessWidget {
  const AttachmentBar({
    super.key,
    required this.attachments,
    required this.maxCount,
    required this.hint,
    required this.onAdd,
    required this.onRemoveAt,
  });

  final List<MediaAttachment> attachments;
  final int maxCount;

  /// One-line prompt telling the user why an image is needed (e.g. video needs
  /// a starting image).
  final String hint;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;

  static const _thumbSize = 56.0;

  Future<void> _pick() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    onAdd(MediaAttachment(filename: file.name, bytes: bytes));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = attachments.length >= maxCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
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
            if (!full)
              _AddTile(size: _thumbSize, onTap: _pick),
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
