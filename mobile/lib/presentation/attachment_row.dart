/// The files staged against the next message, and the way to add one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../logic/phone_attachments.dart';
import '../logic/phone_uploads.dart';

/// Picks a photo or a document and stages it against [chatId].
///
/// Two sources rather than one, because iOS treats them as two things: photos
/// live in a library the system hands out one picture at a time, and everything
/// else comes from the Files sheet. A single "attach" button that opened only
/// one of them would silently be missing half of what people want to send.
class AttachButton extends ConsumerWidget {
  const AttachButton(this.chatId, {super.key});

  /// Which chat these belong to.
  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return IconButton(
      tooltip: 'Attach',
      iconSize: 20,
      color: AppPalette.textSecondary,
      style: IconButton.styleFrom(minimumSize: const Size.square(40)),
      icon: const Icon(Icons.add_rounded),
      onPressed: () => _choose(context, ref),
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final source = await showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.of(sheet).pop(_Source.photo),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('File'),
              onTap: () => Navigator.of(sheet).pop(_Source.file),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    final picked = switch (source) {
      _Source.photo => await _photo(),
      _Source.file => await _file(),
    };
    if (picked == null || !context.mounted) return;
    final added = ref.read(attachmentsProvider(chatId).notifier).add(picked);
    if (added) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('That is as many files as one message can carry.'),
      ),
    );
  }

  Future<OutgoingFile?> _photo() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null) return null;
    return (name: image.name, bytes: await image.readAsBytes());
  }

  Future<OutgoingFile?> _file() async {
    final file = await openFile();
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }
}

enum _Source { photo, file }

/// What is staged, with a way to take each one back off.
class AttachmentChips extends ConsumerWidget {
  const AttachmentChips(this.chatId, {super.key});

  /// Which chat.
  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final staged = ref.watch(attachmentsProvider(chatId));
    if (staged.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (index, file) in staged.indexed)
            Chip(
              label: Text(file.name, overflow: TextOverflow.ellipsis),
              // The size is on the chip because it is the one thing that
              // decides whether this send takes a second or a minute on a
              // phone connection.
              avatar: Text(
                _size(file.bytes.length),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              onDeleted: () => ref
                  .read(attachmentsProvider(chatId).notifier)
                  .removeAt(index),
            ),
        ],
      ),
    );
  }
}

/// A byte count as a person reads it.
String _size(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}K';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
}
