import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/host_arch.dart';
import 'package:grid_app/features/browser/logic/browser_tab_controller.dart';
import 'package:grid_app/features/files/logic/files_browser.dart';
import 'package:grid_app/features/terminal/logic/terminal_sessions_controller.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/panels/panel_memory.dart';
import 'package:grid_app/shared/panels/panel_memory_controller.dart';
import 'package:grid_app/shared/panels/panel_scope.dart';
import 'package:grid_app/shared/panels/panel_tabs.dart';

/// Which project the chat on screen is in, as the test says — standing in for
/// the chat's own history, which would read a real `~/.grid` to answer.
class _OnScreen extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? scope) => state = scope;
}

final _onScreenProvider = NotifierProvider<_OnScreen, String?>(_OnScreen.new);

/// A page that notes what it was asked to load and draws nothing.
class _FakePage implements BrowserPageHandle {
  final loads = <String>[];

  @override
  Future<void> load(String url) async => loads.add(url);

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> back() async {}

  @override
  Future<void> forward() async {}

  @override
  Future<Object?> evaluate(String source) async => null;

  @override
  Future<Uint8List?> screenshot() async => null;
}

const _side = PanelHost.preview;

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('panel_memory_');
    // Registered first so it runs last, after every container has let go.
    addTearDown(() => home.deleteSync(recursive: true));
  });

  /// One launch of the app against [home]: its own container, with the panel
  /// memory started the way the shell starts it.
  ProviderContainer launch() {
    final c = ProviderContainer(
      overrides: [
        panelMemoryStoreProvider.overrideWithValue(
          PanelMemoryStore(dir: Directory('${home.path}/panel_tabs')),
        ),
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${home.path}/chat_prefs.json')),
        ),
        // No real shell: what's under test is which terminals stay alive.
        shellStarterProvider.overrideWithValue((session, onError) {}),
        panelScopeProvider.overrideWith(
          (ref, host) => host == _side ? ref.watch(_onScreenProvider) : null,
        ),
      ],
    );
    addTearDown(c.dispose);
    // Listened to, as the shell does: a provider nobody listens to is paused,
    // and hears none of the project changes below.
    c.listen(panelMemoryProvider(_side), (_, _) {});
    c.read(panelMemoryProvider(_side).notifier).start();
    return c;
  }

  Future<void> goTo(ProviderContainer c, String scope) async {
    c.read(_onScreenProvider.notifier).set(scope);
    await c.pump();
  }

  PanelTabs tabs(ProviderContainer c) =>
      c.read(panelTabsProvider(_side).notifier);

  PanelTabsState tabsOf(ProviderContainer c) =>
      c.read(panelTabsProvider(_side));

  group('moving between projects', () {
    test('a project never opened beside starts with the panel shut', () async {
      // The whole complaint: a browser opened beside one project's chat was
      // still there beside every other project's.
      final c = launch();
      await goTo(c, 'notes');
      tabs(c).open(PanelFeature.files);

      await goTo(c, 'app');

      expect(tabsOf(c).tabs, isEmpty);
      expect(c.read(panelOpenProvider(_side)), isFalse);
    });

    test('coming back finds its own tabs, shells still running', () async {
      // Parked, not closed: a build running in a terminal must survive the
      // user glancing at another project.
      final c = launch();
      await goTo(c, 'app');
      final shell = tabs(c).open(PanelFeature.terminal);
      c
          .read(terminalSessionsProvider.notifier)
          .ensure(tabId: shell, workdir: '/p/app');

      await goTo(c, 'notes');
      await goTo(c, 'app');

      expect(tabsOf(c).activeId, shell);
      expect(c.read(panelOpenProvider(_side)), isTrue);
      expect(c.read(terminalSessionsProvider)[shell], isNotNull);
    });
  });

  group('across launches', () {
    test('a Files tab reopens on the file it showed, folders open', () async {
      final first = launch();
      await goTo(first, 'app');
      final files = tabs(first).open(PanelFeature.files);
      first.read(filesBrowserProvider(files).notifier)
        ..reveal(path: '/p/app/lib/main.dart', root: '/p/app')
        ..toggleTree();
      tabs(first)
        ..open(PanelFeature.review)
        ..select(files);
      first.dispose();

      final next = launch();
      await goTo(next, 'app');

      final restored = tabsOf(next);
      expect(restored.tabs.map((t) => t.feature), [
        PanelFeature.files,
        PanelFeature.review,
      ]);
      expect(restored.activeId, restored.tabs.first.id);
      expect(next.read(panelOpenProvider(_side)), isTrue);
      final place = next.read(filesBrowserProvider(restored.tabs.first.id));
      expect(place.selected, '/p/app/lib/main.dart');
      expect(place.expanded, contains('/p/app/lib'));
      expect(place.showTree, isFalse);
    });

    test('a browser tab reopens and loads the page it was on', () async {
      final first = launch();
      await goTo(first, 'app');
      final id = tabs(first).open(PanelFeature.browser);
      first
          .read(browserTabProvider(id).notifier)
          .submit('https://example.com/docs');
      first.dispose();

      final next = launch();
      await goTo(next, 'app');

      final tab = tabsOf(next).tabs.single;
      expect(tab.feature, PanelFeature.browser);
      final page = _FakePage();
      next.read(browserTabProvider(tab.id).notifier).attach(page);
      expect(page.loads, ['https://example.com/docs']);
    }, skip: embeddedWebSupported ? false : 'no web engine on this computer');

    test('a panel left shut comes back shut, its tabs behind it', () async {
      final first = launch();
      await goTo(first, 'app');
      tabs(first).open(PanelFeature.review);
      first.read(panelOpenProvider(_side).notifier).close();
      first.dispose();

      final next = launch();
      await goTo(next, 'app');

      expect(next.read(panelOpenProvider(_side)), isFalse);
      expect(tabsOf(next).tabs.single.feature, PanelFeature.review);
    });

    test('tabs opened before the project was known are kept', () async {
      // The history takes a moment to read, and a tab opened in it is one the
      // user asked for just now — last launch's tabs must not replace it.
      final first = launch();
      await goTo(first, 'app');
      tabs(first).open(PanelFeature.review);
      first.dispose();

      final next = launch();
      final early = tabs(next).open(PanelFeature.files);
      await goTo(next, 'app');

      expect(tabsOf(next).tabs.map((t) => t.id), [early]);
    });
  });

  group('the file', () {
    test('what is written reads back as the same memory', () {
      // The controller only writes when the memory changed, so a round trip
      // that came back different would rewrite the file on every launch.
      final memory = PanelScopeMemory(
        open: true,
        active: 1,
        tabs: [
          const PanelTabMemory(
            feature: PanelFeature.browser,
            title: 'Docs',
            url: 'https://example.com',
          ),
          PanelTabMemory(
            feature: PanelFeature.files,
            title: 'Files',
            files: FilesBrowserState(
              root: '/p',
              selected: '/p/a.md',
              expanded: {'/p/lib'},
              showTree: false,
            ),
          ),
        ],
      );

      final read = PanelScopeMemory.fromJson(
        jsonDecode(jsonEncode(memory.toJson())),
      );

      expect(read, memory);
    });

    test('a tab this build cannot open is dropped, the front one kept', () {
      final memory = PanelScopeMemory.fromJson(
        jsonDecode('''
          {"open": true, "active": 2, "tabs": [
            {"feature": "review"},
            {"feature": "hologram"},
            {"feature": "files", "files": {"selected": "/p/notes.md"}}
          ]}
        '''),
      )!;

      expect(memory.tabs.map((t) => t.feature), [
        PanelFeature.review,
        PanelFeature.files,
      ]);
      expect(memory.active, 1);
      expect(memory.tabs.last.files?.selected, '/p/notes.md');
    });

    test('a corrupt file reads as nothing remembered', () {
      final dir = Directory('${home.path}/panel_tabs')..createSync();
      File('${dir.path}/preview.json').writeAsStringSync('{not json');

      expect(PanelMemoryStore(dir: dir).load(PanelHost.preview), isEmpty);
    });
  });

  group('a browser tab', () {
    test('a new engine goes back to the page instead of sitting blank', () {
      // The engine goes with the widget — a project parked, the panel moving
      // between docked and floating — while the tab's controller stays.
      final c = launch();
      final tab = c.read(browserTabProvider('t').notifier)
        ..submit('https://example.com')
        ..attach(_FakePage())
        ..reportLoadStop('https://example.com');

      final again = _FakePage();
      tab.attach(again);

      expect(again.loads, ['https://example.com']);
    });

    test('a remembered address with no web scheme is not followed', () {
      // Read off disk, so a hand-edited `mailto:` must not open the mail app
      // on launch, and a bare word must not become a search.
      final c = launch();
      c.read(browserTabProvider('t').notifier)
        ..restore('mailto:someone@example.com')
        ..restore('react hooks');

      expect(c.read(browserTabProvider('t')).url, isEmpty);
    });
  });
}
