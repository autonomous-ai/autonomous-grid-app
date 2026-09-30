import 'package:grid_app/infrastructure/pairing_host/mobile_turn_controls.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// A turn in flight with no app behind it — what the RPC layer is handed in
/// place of the running window, recording what a phone asked it to do.
class FakeTurns implements MobileTurnControls {
  FakeTurns({
    this.busy = true,
    this.writing = '',
    this.ran = const [],
    this.asking,
  });

  bool busy;
  final String writing;
  final List<MobileStep> ran;
  MobilePermission? asking;

  final stopped = <String>[];
  final answered = <String>[];

  @override
  bool isBusy(String chatId) => busy;

  @override
  String streaming(String chatId) => writing;

  @override
  ({List<MobileStep> steps, int count}) steps(
    String chatId, {
    required int newest,
  }) => (steps: newestOf(ran, newest), count: ran.length);

  @override
  MobilePermission? permission(String chatId) => asking;

  @override
  bool stop(String chatId) {
    if (!busy) return false;
    stopped.add(chatId);
    busy = false;
    return true;
  }

  @override
  String? answer(
    String chatId,
    String questionId,
    MobilePermissionChoice choice,
  ) {
    if (asking?.id != questionId) return 'That question has already closed.';
    answered.add('$chatId/$questionId=${choice.name}');
    asking = null;
    return null;
  }
}

/// A step the fake can report, numbered so order is visible in a failure.
MobileStep fakeStep(int n, {MobileStepStatus? status}) => MobileStep(
  id: 's$n',
  kind: MobileStepKind.command,
  label: 'step $n',
  status: status ?? MobileStepStatus.done,
);
