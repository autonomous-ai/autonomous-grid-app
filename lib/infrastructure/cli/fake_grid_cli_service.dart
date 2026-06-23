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
  })  : _results = results ?? {},
        _runs = {},
        _pulls = pulls ?? {};

  final Map<String, CliResult> _results;
  final Map<String, _FakeRun> _runs;
  final Map<String, List<DownloadProgress>> _pulls;

  static String keyOf(List<String> args) => args.join(' ');

  void stubResult(List<String> args, CliResult result) =>
      _results[keyOf(args)] = result;

  void stubStart(
    List<String> args, {
    required List<CliLine> lines,
    int exitCode = 0,
    Duration exitDelay = const Duration(milliseconds: 1),
  }) =>
      _runs[keyOf(args)] = _FakeRun(lines, exitCode, exitDelay);

  void stubPull(List<String> args, List<DownloadProgress> progress) =>
      _pulls[keyOf(args)] = progress;

  @override
  Future<CliResult> run(List<String> args) async {
    return _results[keyOf(args)] ??
        const CliResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<GridProcess> start(List<String> args) async {
    final run = _runs[keyOf(args)] ?? const _FakeRun([], 0, Duration.zero);
    return GridProcess(
      lines: Stream.fromIterable(run.lines),
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
  const _FakeRun(this.lines, this.exitCode, this.exitDelay);
  final List<CliLine> lines;
  final int exitCode;
  final Duration exitDelay;
}
