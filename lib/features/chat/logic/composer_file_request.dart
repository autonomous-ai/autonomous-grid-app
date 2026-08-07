import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Files a panel has asked to put on the next message.
///
/// The sibling of `composerPrefillProvider`: a panel beside the conversation
/// says what it wants sent, and the composer decides what to do with it —
/// offered rather than attached directly, because the message belongs to the
/// composer. It is the one holding the budget, the chips and the draft.
///
/// **Asked for, never assumed.** Files used to put whatever tab was *showing*
/// onto the message and swap it as the user clicked around; that read as the
/// app attaching things behind their back, so browsing does nothing now and the
/// only way onto a message is a right-click and "Add to chat". Which also means
/// this is additive: two files asked for are two chips, and neither replaces the
/// other.
final composerFileRequestProvider =
    NotifierProvider<ComposerFileRequest, List<String>>(
      ComposerFileRequest.new,
    );

class ComposerFileRequest extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void add(String path) => state = [...state, path];

  /// The composer has them — forget them, so they aren't attached twice.
  void taken() => state = const [];
}
