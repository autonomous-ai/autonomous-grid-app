import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/local_files.dart';
import 'model_group.dart';
import 'models_providers.dart';

final modelPullControllerProvider =
    NotifierProvider<ModelPullController, ModelPullState>(
      ModelPullController.new,
    );

/// Splits the download box into individual `<repo>:<file>` specs — one per line.
/// Blank lines and surrounding whitespace are ignored; order is preserved and
/// duplicates dropped, so pasting a 5-line split model pulls each part once.
List<String> parsePullSpecs(String input) {
  final seen = <String>{};
  final specs = <String>[];
  for (final line in input.split('\n')) {
    final spec = line.trim();
    if (spec.isEmpty || !seen.add(spec)) continue;
    specs.add(spec);
  }
  return specs;
}

sealed class ModelPullState {
  const ModelPullState();
}

class ModelPullIdle extends ModelPullState {
  const ModelPullIdle();
}

/// Download in progress. [progress] is null until the first parsable bar
/// arrives (callers show an indeterminate spinner meanwhile). [current]/[total]
/// track position within a multi-file batch (a split model's parts) — both are 1
/// for a single-file download.
class ModelPulling extends ModelPullState {
  const ModelPulling({
    required this.spec,
    this.progress,
    this.current = 1,
    this.total = 1,
  });
  final String spec;
  final DownloadProgress? progress;
  final int current;
  final int total;
}

class ModelPullDone extends ModelPullState {
  const ModelPullDone(this.file);
  final String file;
}

class ModelPullFailed extends ModelPullState {
  const ModelPullFailed(this.message);
  final String message;
}

/// Runs `grid pull <repo>:<file>` for each requested spec, streaming the stderr
/// download bar (§3.4). One line pulls one file; several lines pull a split
/// model's parts in turn (they all land flat in `~/.grid/models`, where the
/// engine loads siblings by convention). `pull()` doesn't surface an exit code,
/// so success is confirmed by re-scanning `~/.grid/models` for each target file.
class ModelPullController extends Notifier<ModelPullState> {
  /// Live download subscription, so [cancel] can tear it down (which SIGTERMs
  /// the `grid pull` process via the stream's onCancel). Null when idle.
  StreamSubscription<DownloadProgress>? _sub;

  /// Completes when the current download stream ends — by finishing, erroring,
  /// or being [cancel]led — so each step can await one terminal outcome.
  Completer<void>? _completer;

  /// True while a [cancel] is being honoured, so [pull] skips its
  /// success/failure handling and leaves the idle state cancel set.
  bool _cancelled = false;

  @override
  ModelPullState build() {
    ref.onDispose(() => _sub?.cancel());
    return const ModelPullIdle();
  }

  /// Downloads every spec found in [input] (one per line). Stops on the first
  /// failure — a split model is useless with a missing part — and reports which
  /// line failed.
  Future<void> pull(String input) async {
    final specs = parsePullSpecs(input);
    if (specs.isEmpty) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ModelPullFailed(
        "Grid's background helper isn't available — please restart the app.",
      );
      return;
    }

    _cancelled = false;
    for (var i = 0; i < specs.length; i++) {
      final spec = specs[i];
      state = ModelPulling(spec: spec, current: i + 1, total: specs.length);
      final failed = await _runOne(
        service,
        spec,
        current: i + 1,
        total: specs.length,
      );

      // [cancel] already reset the state to idle; don't clobber it.
      if (_cancelled) return;
      if (failed) {
        state = ModelPullFailed(
          specs.length == 1
              ? "Couldn't download the model — check your internet connection and "
                    'that the model name is correct, then try again.'
              : "Couldn't download '$spec' — check your internet connection and "
                    'that every line is correct, then try again.',
        );
        return;
      }
    }

    // Refresh the on-disk list and confirm every requested file actually landed.
    // The `.part` is gone (renamed to `.gguf`) now, so rescan the downloads too.
    ref.invalidate(localModelsProvider);
    ref.invalidate(downloadingModelsProvider);
    final models = ref.read(localModelsProvider);
    final targets = [
      for (final spec in specs)
        if (spec.contains(':')) spec.split(':').last,
    ];
    final allLanded = targets.every((target) => _landed(models, target));

    if (targets.isEmpty || allLanded) {
      state = ModelPullDone(_doneLabel(targets, specs));
    } else {
      state = const ModelPullFailed(
        "The download finished but the model couldn't be found afterwards. "
        'Check the model name and try again.',
      );
    }
  }

  /// Streams one `grid pull <spec>` to completion, forwarding progress. Returns
  /// true when the download errored. Shared by every step of a multi-file batch.
  Future<bool> _runOne(
    GridCliService service,
    String spec, {
    required int current,
    required int total,
  }) async {
    final completer = Completer<void>();
    _completer = completer;
    var failed = false;
    void settle() {
      if (!completer.isCompleted) completer.complete();
    }

    _sub = service
        .pull(['pull', spec])
        .listen(
          (progress) => state = ModelPulling(
            spec: spec,
            progress: progress,
            current: current,
            total: total,
          ),
          onError: (Object _) {
            failed = true;
            settle();
          },
          onDone: settle,
          cancelOnError: true,
        );

    await completer.future;
    await _sub?.cancel();
    _sub = null;
    _completer = null;
    return failed;
  }

  /// Lenient (case-insensitive, by filename) landed check, so a slightly
  /// different saved name doesn't read as a failure when the download succeeded.
  bool _landed(List<LocalModel> models, String target) {
    final want = target.toLowerCase();
    return models.any((model) {
      final name = model.name.toLowerCase();
      return name == want || name.endsWith(want) || name.contains(want);
    });
  }

  /// A human summary of what finished: the single filename, or the shared base
  /// name plus a part count for a split model (`MiniMax-M3-UD-IQ3_XXS (5 parts)`).
  String _doneLabel(List<String> targets, List<String> specs) {
    final files = targets.isEmpty ? specs : targets;
    if (files.length == 1) return files.first;
    return '${stripSplitSuffix(files.first)} (${files.length} parts)';
  }

  /// Stop an in-progress download and return to idle. Cancels the stream, which
  /// SIGTERMs the `grid pull` process so the transfer actually stops rather than
  /// finishing in the background. No-op when nothing is downloading.
  Future<void> cancel() async {
    if (state is! ModelPulling) return;
    _cancelled = true;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (!(_completer?.isCompleted ?? true)) _completer!.complete();
    state = const ModelPullIdle();
  }

  void reset() => state = const ModelPullIdle();
}
