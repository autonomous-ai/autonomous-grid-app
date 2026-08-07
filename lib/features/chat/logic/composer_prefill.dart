import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A message some other surface wants the user to send.
///
/// Offered to the composer rather than sent: what answers a turn is the model
/// and the agent chosen down there, and a panel firing a message off on the
/// user's behalf would spend their grid on a turn they never read. Putting the
/// words in the box leaves the decision — and the wording — with them.
///
/// Null once the composer has taken it, so re-opening a panel doesn't re-fill a
/// box the user has already emptied.
final composerPrefillProvider = NotifierProvider<ComposerPrefill, String?>(
  ComposerPrefill.new,
);

class ComposerPrefill extends Notifier<String?> {
  @override
  String? build() => null;

  /// Put [text] in the composer, replacing whatever draft is there.
  void offer(String text) => state = text;

  /// The composer has it — forget it, so it isn't offered twice.
  void taken() => state = null;
}
