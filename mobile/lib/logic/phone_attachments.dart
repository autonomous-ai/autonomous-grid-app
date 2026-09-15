/// The files staged against a chat's composer, before they are sent with it.
///
/// Kept per chat, in a controller rather than in the composer's own state, for
/// the reason the send controller exists: choosing a photo opens a system sheet
/// and comes back much later, and a widget that was rebuilt in between would
/// have lost what was chosen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_uploads.dart';

/// What is attached to one chat's next message.
final attachmentsProvider =
    NotifierProvider.family<AttachmentsController, List<PickedFile>, String>(
      AttachmentsController.new,
    );

/// Holds what has been picked for one chat.
class AttachmentsController extends Notifier<List<PickedFile>> {
  AttachmentsController(this.chatId);

  /// The conversation these belong to — the family argument, so one chat's
  /// photo never rides along with another chat's question.
  final String chatId;

  @override
  List<PickedFile> build() => const [];

  /// Stages [file], unless the composer is already full.
  ///
  /// Returns false when it was not added, so the caller can say why rather than
  /// dropping it silently.
  bool add(PickedFile file) {
    if (state.length >= kMaxAttachments) return false;
    state = [...state, file];
    return true;
  }

  /// Drops the one at [index].
  void removeAt(int index) => state = [
    for (final (position, file) in state.indexed)
      if (position != index) file,
  ];

  /// Drops all of them — after a send, or when the person clears the box.
  void clear() => state = const [];
}
