import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/model_pull_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

class _FakeStore extends GridHomeStore {
  const _FakeStore(this.models);
  final List<LocalModel> models;

  @override
  List<LocalModel> listLocalModels() => models;
}

/// A CLI whose `pull` never finishes on its own, recording whether the stream
/// was cancelled — stands in for an in-flight download the user stops mid-way.
class _HangingPullCli implements GridCliService {
  bool cancelled = false;

  @override
  Stream<DownloadProgress> pull(List<String> args) {
    late final StreamController<DownloadProgress> controller;
    controller = StreamController<DownloadProgress>(
      onListen: () =>
          controller.add(const DownloadProgress(doneMb: 1, totalMb: 100, pct: 1)),
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  @override
  Future<CliResult> run(List<String> args) async =>
      const CliResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<GridProcess> start(List<String> args) async =>
      throw UnimplementedError();
}

LocalModel _model(String name) =>
    LocalModel(name: name, path: '/models/$name', sizeBytes: 1);

ProviderContainer _container(GridCliService cli, List<LocalModel> onDisk) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(cli),
    gridHomeStoreProvider.overrideWithValue(_FakeStore(onDisk)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('streams progress then completes when the file lands', () async {
    final fake = FakeGridCliService()
      ..stubPull(['pull', 'repo:qwen.gguf'], const [
        DownloadProgress(doneMb: 10, totalMb: 100, pct: 10),
        DownloadProgress(doneMb: 100, totalMb: 100, pct: 100),
      ]);
    final container = _container(fake, [_model('qwen.gguf')]);

    final seen = <ModelPullState>[];
    container.listen(modelPullControllerProvider, (_, next) => seen.add(next));

    await container.read(modelPullControllerProvider.notifier).pull('repo:qwen.gguf');

    final state = container.read(modelPullControllerProvider);
    expect(state, isA<ModelPullDone>());
    expect((state as ModelPullDone).file, 'qwen.gguf');
    expect(
      seen.whereType<ModelPulling>().where((s) => s.progress != null),
      isNotEmpty,
    );
  });

  test('fails when the target file never appears', () async {
    final fake = FakeGridCliService()
      ..stubPull(['pull', 'repo:missing.gguf'], const []);
    final container = _container(fake, const []);

    await container.read(modelPullControllerProvider.notifier).pull('repo:missing.gguf');

    expect(container.read(modelPullControllerProvider), isA<ModelPullFailed>());
  });

  test('fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container.read(modelPullControllerProvider.notifier).pull('repo:x.gguf');

    expect(container.read(modelPullControllerProvider), isA<ModelPullFailed>());
  });

  test('cancel stops an in-progress download and returns to idle', () async {
    final cli = _HangingPullCli();
    final container = _container(cli, const []);
    final notifier = container.read(modelPullControllerProvider.notifier);

    // Start but don't await — the download hangs until cancelled.
    final pulling = notifier.pull('repo:big.gguf');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(modelPullControllerProvider), isA<ModelPulling>());

    await notifier.cancel();
    await pulling;

    expect(container.read(modelPullControllerProvider), isA<ModelPullIdle>());
    // The underlying stream was cancelled, so the `grid pull` process is killed.
    expect(cli.cancelled, isTrue);
  });

  test('cancel is a no-op when nothing is downloading', () async {
    final container = _container(FakeGridCliService(), const []);
    final notifier = container.read(modelPullControllerProvider.notifier);

    await notifier.cancel();

    expect(container.read(modelPullControllerProvider), isA<ModelPullIdle>());
  });
}
