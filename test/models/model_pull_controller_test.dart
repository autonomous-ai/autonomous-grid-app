import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/model_pull_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
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

LocalModel _model(String name) =>
    LocalModel(name: name, path: '/models/$name', sizeBytes: 1);

ProviderContainer _container(FakeGridCliService fake, List<LocalModel> onDisk) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(fake),
    gridHomeStoreProvider.overrideWithValue(_FakeStore(onDisk)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('streams progress then completes when the file lands', () async {
    final fake = FakeGridCliService()
      ..stubPull(['models', 'pull', 'repo:qwen.gguf'], const [
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
      ..stubPull(['models', 'pull', 'repo:missing.gguf'], const []);
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
}
