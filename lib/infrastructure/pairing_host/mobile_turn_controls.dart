/// The turn a chat has in flight, as a paired phone may see and steer it.
///
/// An interface rather than a row of closures because it is one thing — the
/// running app's view of an agent turn — and the phone needs six facts and
/// actions about it. Flutter-free like the rest of this folder; the app
/// implements it (`features/phone/logic/phone_turn_controls.dart`) and a test
/// hands in a fake.
library;

import 'package:grid_pairing/grid_pairing.dart';

/// What the running app knows about a chat's turn in flight, and the two
/// things a phone may do to it.
abstract interface class MobileTurnControls {
  /// Whether an answer is still being written in [chatId].
  bool isBusy(String chatId);

  /// The answer as far as it has been written — empty when none is.
  String streaming(String chatId);

  /// The newest [newest] steps of the running turn, and how many it has run.
  ({List<MobileStep> steps, int count}) steps(
    String chatId, {
    required int newest,
  });

  /// The question the agent in [chatId] is waiting on, or null.
  MobilePermission? permission(String chatId);

  /// Stops the answer being written in [chatId]. False when there was none.
  bool stop(String chatId);

  /// Answers question [questionId] in [chatId]. Null once it is answered, or a
  /// sentence to show — the question has closed, or been replaced by the next.
  String? answer(
    String chatId,
    String questionId,
    MobilePermissionChoice choice,
  );
}
