import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/cli/remote_mode_grid_cli_service.dart';

/// Records the args each entrypoint is called with, so we can assert exactly
/// what [RemoteModeGridCliService] forwards to the inner service.
class _RecordingCliService implements GridCliService {
  final List<List<String>> runArgs = [];
  final List<List<String>> startArgs = [];
  final List<List<String>> pullArgs = [];

  @override
  Future<CliResult> run(List<String> args) async {
    runArgs.add(args);
    return const CliResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<GridProcess> start(List<String> args) async {
    startArgs.add(args);
    return GridProcess(
      lines: const Stream.empty(),
      exitCode: Future.value(0),
      kill: () {},
    );
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) {
    pullArgs.add(args);
    return const Stream.empty();
  }
}

void main() {
  late _RecordingCliService inner;
  late RemoteModeGridCliService sut;

  setUp(() {
    inner = _RecordingCliService();
    sut = RemoteModeGridCliService(inner);
  });

  group('prepends --remote for remote commands', () {
    test('run', () async {
      await sut.run(['login']);
      expect(inner.runArgs.single, ['--remote', 'login']);
    });

    test('start', () async {
      await sut.start(['join', 'grid.example']);
      expect(inner.startArgs.single, ['--remote', 'join', 'grid.example']);
    });

    test('pull', () async {
      sut.pull(['models', 'pull', 'qwen']).listen(null);
      expect(inner.pullArgs.single, ['--remote', 'models', 'pull', 'qwen']);
    });
  });

  group('drops --remote for local engine commands', () {
    // `grid --remote engine install` builds against the remote/CUDA path and
    // fails on a Mac ("No NVIDIA GPUs detected"); the engine family is local.
    test('engine install llama.cpp starts without --remote', () async {
      await sut.start(['engine', 'install', 'llama.cpp']);
      expect(inner.startArgs.single, ['engine', 'install', 'llama.cpp']);
    });

    test('engine install comfyui starts without --remote', () async {
      await sut.start(['engine', 'install', 'comfyui']);
      expect(inner.startArgs.single, ['engine', 'install', 'comfyui']);
    });

    test('engine status runs without --remote', () async {
      await sut.run(['engine', 'status']);
      expect(inner.runArgs.single, ['engine', 'status']);
    });

    test('engine pull runs without --remote', () async {
      sut.pull(['engine', 'pull', 'sdxl']).listen(null);
      expect(inner.pullArgs.single, ['engine', 'pull', 'sdxl']);
    });
  });

  test('empty args are forwarded unchanged (no crash on args.first)', () async {
    await sut.run(const []);
    expect(inner.runArgs.single, ['--remote']);
  });
}
