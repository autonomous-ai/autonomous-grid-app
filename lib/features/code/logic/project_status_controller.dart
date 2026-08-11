import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_projects_controller.dart';
import 'poll_cadence.dart';
import 'project_status.dart';

/// Where the open project is, from this member's side — refreshed on a timer
/// while the screen is open.
final projectStatusProvider = AsyncNotifierProvider.autoDispose
    .family<ProjectStatusController, ProjectStatus, String>(
      ProjectStatusController.new,
      retry: neverRetryCodeCommand,
    );

class ProjectStatusController extends AsyncNotifier<ProjectStatus> {
  ProjectStatusController(this.projectId);

  /// The project this status is about — the family argument.
  final String projectId;

  Timer? _timer;

  @override
  Future<ProjectStatus> build() async {
    ref.onDispose(() => _timer?.cancel());
    final status = await _read(projectId);
    _schedule(status);
    return status;
  }

  Future<ProjectStatus> _read(String projectId) async {
    final grid = ref.read(codeGridIdProvider);
    if (grid == null) {
      throw const CodeGridException('Pick a grid first.');
    }
    final cli = ref.read(codeCliProvider);
    if (cli == null) {
      throw const CodeGridException(
        "The grid tool isn't available on this computer.",
      );
    }
    final json = await cli.object(
      projectStatusArgs(projectId: projectId, grid: grid),
    );
    final status = ProjectStatus.fromJson(json);
    if (status == null) {
      // A reply with no branch is not a status. Rendering the screen with
      // blanks in it would read as "you have no work here", which is the one
      // answer nobody should get from a body that arrived mangled.
      throw const CodeGridException(
        'The grid did not say where this project is, so nothing here can be '
        'trusted yet. Try again in a moment.',
      );
    }
    return status;
  }

  void _schedule(ProjectStatus status) {
    _timer?.cancel();
    final busy = status.slotHolder != null || status.queue.isBusy;
    _timer = Timer(busy ? kBusyPoll : kIdlePoll, _tick);
  }

  Future<void> _tick() async {
    // A failed poll must not blank a screen that is showing good data: the next
    // tick is scheduled either way, and a grid that blinks for one request is
    // the ordinary case rather than an error worth clearing the pane for.
    try {
      final status = await _read(projectId);
      // The screen may have closed while the request was in flight; writing
      // state into a disposed notifier throws, and a poll may not be the thing
      // that takes the app down.
      if (!ref.mounted) return;
      state = AsyncData(status);
      _schedule(status);
    } on Object {
      if (!ref.mounted) return;
      _timer?.cancel();
      _timer = Timer(kIdlePoll, _tick);
    }
  }

  /// Read it again now — after an action that moved a ref, so the screen shows
  /// the grid's own view rather than an optimistic guess.
  Future<void> refresh() async {
    state = await AsyncValue.guard(() => _read(projectId));
    final status = state.asData?.value;
    if (status != null) _schedule(status);
  }
}
