import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/prompts/logic/prompt_library_controller.dart';
import 'package:grid_app/features/prompts/logic/prompt_library_store.dart';
import 'package:grid_app/features/prompts/logic/saved_prompt.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grid_prompts_test');
    file = File('${dir.path}/prompts.json');
  });
  tearDown(() => dir.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        promptLibraryStoreProvider.overrideWithValue(
          PromptLibraryStore(file: file),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a fresh library is empty and does not throw on a missing file', () {
    expect(container().read(promptLibraryProvider), isEmpty);
  });

  test('add slugs the name so it stays one /-command, and trims the body', () {
    final c = container();
    c
        .read(promptLibraryProvider.notifier)
        .add(name: '  Weekly report  ', body: '  Do the thing  ');

    final prompts = c.read(promptLibraryProvider);
    expect(prompts, hasLength(1));
    // Spaces would close the slash menu at the first one — the name is a token.
    expect(prompts.single.name, 'Weekly-report');
    expect(prompts.single.body, 'Do the thing');
  });

  test('edit slugs the new name too', () {
    final c = container();
    final notifier = c.read(promptLibraryProvider.notifier);
    final a = notifier.add(name: 'draft', body: 'x');

    notifier.edit(id: a.id, name: 'tank attack game', body: 'x');

    expect(c.read(promptLibraryProvider).single.name, 'tank-attack-game');
  });

  test(
    'a library saved with spaced names before this rule reads as slugs '
    'right away — the user\'s "tank 1990" is typeable without re-saving it',
    () {
      // Seed the file the way an older build left it.
      PromptLibraryStore(file: file).save(const [
        SavedPrompt(id: 'p1', name: 'tank 1990', body: 'a'),
        SavedPrompt(id: 'p2', name: 'tank 2026', body: 'b'),
      ]);

      expect(container().read(promptLibraryProvider).map((p) => p.name), [
        'tank-1990',
        'tank-2026',
      ]);
    },
  );

  test('a saved prompt survives a reload — it was written to disk', () {
    container()
        .read(promptLibraryProvider.notifier)
        .add(name: 'Report', body: 'x');

    // A second container reads the same file from scratch, as a relaunch would.
    expect(container().read(promptLibraryProvider).single.name, 'Report');
  });

  test('edit rewrites the matching prompt and leaves the rest alone', () {
    final c = container();
    final notifier = c.read(promptLibraryProvider.notifier);
    final a = notifier.add(name: 'A', body: 'a');
    final b = notifier.add(name: 'B', body: 'b');

    notifier.edit(id: a.id, name: 'A2', body: 'a2');

    final prompts = c.read(promptLibraryProvider);
    expect(prompts.firstWhere((p) => p.id == a.id).name, 'A2');
    expect(prompts.firstWhere((p) => p.id == b.id).name, 'B');
  });

  test('remove drops just that prompt', () {
    final c = container();
    final notifier = c.read(promptLibraryProvider.notifier);
    final a = notifier.add(name: 'A', body: 'a');
    notifier.add(name: 'B', body: 'b');

    notifier.remove(a.id);

    final prompts = c.read(promptLibraryProvider);
    expect(prompts.map((p) => p.name), ['B']);
  });

  test('each added prompt gets its own id', () {
    final c = container();
    final notifier = c.read(promptLibraryProvider.notifier);
    final a = notifier.add(name: 'A', body: 'a');
    final b = notifier.add(name: 'B', body: 'b');
    expect(a.id, isNot(b.id));
  });
}
