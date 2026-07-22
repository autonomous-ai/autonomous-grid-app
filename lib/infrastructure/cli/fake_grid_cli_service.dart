import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// In-memory [GridCliService] for building UI and tests without a real CLI.
///
/// Register canned results per command (matched by the joined args), or rely on
/// the defaults. Lets the whole app run on fixtures (CLI_Integration_Contract §5).
class FakeGridCliService implements GridCliService {
  FakeGridCliService({
    Map<String, CliResult>? results,
    Map<String, List<DownloadProgress>>? pulls,
  }) : _results = results ?? {},
       _runs = {},
       _pulls = pulls ?? {};

  final Map<String, CliResult> _results;
  final Map<String, List<_FakeRun>> _runs;
  final Map<String, List<DownloadProgress>> _pulls;

  static String keyOf(List<String> args) => args.join(' ');

  void stubResult(List<String> args, CliResult result) =>
      _results[keyOf(args)] = result;

  /// Stub a `start` result. Calling it more than once for the same args queues a
  /// sequence consumed call-by-call (e.g. fail-then-succeed for retry tests); a
  /// single stub is reused for every call.
  ///
  /// [lineDelay] spaces the output out instead of delivering it in one burst —
  /// what a real CLI does, and the only way to test what a listener does with a
  /// line that lands *after* the caller has already killed the process.
  void stubStart(
    List<String> args, {
    required List<CliLine> lines,
    int exitCode = 0,
    Duration exitDelay = const Duration(milliseconds: 1),
    Duration lineDelay = Duration.zero,
  }) => (_runs[keyOf(args)] ??= []).add(
    _FakeRun(lines, exitCode, exitDelay, lineDelay),
  );

  void stubPull(List<String> args, List<DownloadProgress> progress) =>
      _pulls[keyOf(args)] = progress;

  /// The [args] and per-call environment of the most recent [start], so tests
  /// can assert a secret (e.g. an API-engine key) was passed via the env channel
  /// rather than on the command line.
  List<String>? lastStartArgs;
  Map<String, String>? lastStartEnvironment;

  @override
  Future<CliResult> run(List<String> args) async {
    return _results[keyOf(args)] ??
        const CliResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    lastStartArgs = args;
    lastStartEnvironment = environment;
    final queue = _runs[keyOf(args)];
    final run = (queue == null || queue.isEmpty)
        ? const _FakeRun([], 0, Duration.zero, Duration.zero)
        : (queue.length == 1 ? queue.first : queue.removeAt(0));
    return GridProcess(
      lines: run.lineDelay == Duration.zero
          ? Stream.fromIterable(run.lines)
          : Stream.fromIterable(
              run.lines,
            ).asyncMap((line) => Future.delayed(run.lineDelay, () => line)),
      // Resolve after lines are delivered so consumers observe output first.
      exitCode: Future.delayed(run.exitDelay, () => run.exitCode),
      kill: () {},
    );
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) async* {
    for (final progress in _pulls[keyOf(args)] ?? const <DownloadProgress>[]) {
      yield progress;
    }
  }
}

class _FakeRun {
  const _FakeRun(this.lines, this.exitCode, this.exitDelay, this.lineDelay);
  final List<CliLine> lines;
  final int exitCode;
  final Duration exitDelay;
  final Duration lineDelay;
}
