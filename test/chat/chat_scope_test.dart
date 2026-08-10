import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_scope.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

/// Where the chat's "who answers me, and with what" choices are remembered.
///
/// The bug this guards against is the one the feature exists to fix: one
/// app-wide pair, so picking Codex for a Flutter repo silently changed the
/// assistant answering in a folder of notes as well.
void main() {
  late Directory tmp;
  late ProjectsStore projects;
  late ChatPrefsStore prefs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_chat_scope_test');
    projects = ProjectsStore(file: File('${tmp.path}/projects.json'));
    prefs = ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json'));
  });
  tearDown(() => tmp.delete(recursive: true));

  /// A container whose open chat sits in [openProjectId] (null for a loose
  /// chat), with both stores pointed at a temp dir so nothing reads or writes a
  /// real `~/.grid`.
  ProviderContainer container({String? openProjectId}) {
    final c = ProviderContainer(
      overrides: [
        projectsStoreProvider.overrideWithValue(projects),
        chatPrefsStoreProvider.overrideWithValue(prefs),
        openChatProjectIdProvider.overrideWithValue(openProjectId),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// A project on disk, so the container's real controller loads it.
  Project seedProject() {
    final project = Project(
      id: 'p1',
      name: 'grid-apis',
      path: '${tmp.path}/grid-apis',
    );
    projects.save([project]);
    return project;
  }

  group('a pick made inside a project', () {
    test('is remembered on that project, leaving the app default alone', () {
      final project = seedProject();
      final c = container(openProjectId: project.id);

      c.read(chatScopePrefsProvider).setAgent('codex');
      c.read(chatScopePrefsProvider).setModel('qwen3-coder');

      final saved = c.read(projectByIdProvider(project.id))!;
      expect(saved.agent, 'codex');
      expect(saved.model, 'qwen3-coder');
      // The app's standing choice is what every chat *outside* a project runs;
      // steering one project must not move it.
      expect(c.read(chatPrefsProvider).chatAgent, ChatPrefs.defaultChatAgent);
      expect(c.read(chatPrefsProvider).model, isNull);
    });

    test('survives the next launch', () {
      final project = seedProject();
      container(
        openProjectId: project.id,
      ).read(chatScopePrefsProvider).setAgent('claude');

      // A fresh container reads the file back, as the next launch would.
      expect(
        container().read(projectByIdProvider(project.id))?.agent,
        'claude',
      );
    });
  });

  group('a pick made in a chat whose project was removed', () {
    test('lands on the app default rather than nowhere', () {
      // The chat still carries the id of a project that has been forgotten.
      // Writing to that id would drop the pick: the user presses Codex and
      // nothing at all happens.
      final c = container(openProjectId: 'forgotten');

      c.read(chatScopePrefsProvider).setAgent('codex');

      expect(c.read(chatPrefsProvider).chatAgent, 'codex');
    });
  });

  group('a pick made in a chat outside every project', () {
    test('is remembered as the app default, touching no project', () {
      final project = seedProject();
      final c = container();

      c.read(chatScopePrefsProvider).setAgent('codex');
      c.read(chatScopePrefsProvider).setModel('llama3');

      expect(c.read(chatPrefsProvider).chatAgent, 'codex');
      expect(c.read(chatPrefsProvider).model, 'llama3');
      expect(c.read(projectByIdProvider(project.id))?.agent, isNull);
      expect(c.read(projectByIdProvider(project.id))?.model, isNull);
    });
  });

  group('the model a chat starts on', () {
    test("is the project's own when it has picked one", () {
      projects.save([
        Project(
          id: 'p1',
          name: 'grid-apis',
          path: '${tmp.path}/grid-apis',
          model: 'qwen3-coder',
        ),
      ]);
      prefs.save(const ChatPrefs(model: 'llama3'));

      expect(
        container(openProjectId: 'p1').read(chatScopeModelProvider),
        'qwen3-coder',
      );
    });

    test('falls back to the app default while the project has picked none', () {
      seedProject();
      prefs.save(const ChatPrefs(model: 'llama3'));

      expect(
        container(openProjectId: 'p1').read(chatScopeModelProvider),
        'llama3',
      );
    });

    test('is null before anything has been picked at all, so the composer '
        "takes the grid's first model", () {
      expect(container().read(chatScopeModelProvider), isNull);
    });
  });
}
