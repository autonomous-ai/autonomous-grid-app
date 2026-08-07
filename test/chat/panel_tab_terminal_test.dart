import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/panel_tabs.dart';
import 'package:grid_app/features/terminal/logic/terminal_sessions_controller.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        // No real shell: what's under test is which terminals get ended, and
        // spawning a login shell per case would make it slow and machine-
        // dependent for nothing.
        shellStarterProvider.overrideWithValue((session, onError) {}),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Opens a Terminal tab in [host] and gives it a shell, the way the tab's view
  /// does on its first frame.
  String openTerminal(ProviderContainer c, PanelHost host, String workdir) {
    c.read(panelTabsProvider(host).notifier).open(PanelFeature.terminal);
    final id = c.read(panelTabsProvider(host)).activeId!;
    c
        .read(terminalSessionsProvider.notifier)
        .ensure(tabId: id, workdir: workdir);
    return id;
  }

  test('closing a tab ends the shell that was running in it', () {
    // Left running, it holds a process the user can no longer see, let alone
    // stop — there is no tab left to press Ctrl+C in.
    final c = container();
    final id = openTerminal(c, PanelHost.preview, '/Users/me/Musiky');
    expect(c.read(terminalSessionsProvider)[id], isNotNull);

    c.read(panelTabsProvider(PanelHost.preview).notifier).close(id);

    expect(c.read(terminalSessionsProvider)[id], isNull);
  });

  test('closing a tab leaves the other panel terminals alone', () {
    final c = container();
    final side = openTerminal(c, PanelHost.preview, '/Users/me/Musiky');
    final below = openTerminal(c, PanelHost.bottom, '/Users/me/Musiky');

    c.read(panelTabsProvider(PanelHost.preview).notifier).close(side);

    expect(c.read(terminalSessionsProvider)[side], isNull);
    expect(c.read(terminalSessionsProvider)[below], isNotNull);
  });

  test('closing the last tab ends its shell and closes the panel', () {
    final c = container();
    final id = openTerminal(c, PanelHost.bottom, '/Users/me/Musiky');

    c.read(panelTabsProvider(PanelHost.bottom).notifier).close(id);

    expect(c.read(terminalSessionsProvider).sessions, isEmpty);
    expect(c.read(panelTabsProvider(PanelHost.bottom)).tabs, isEmpty);
  });

  test('closing a Review tab does not touch a terminal beside it', () {
    // Ending a session is keyed by tab id, so a tab that never had a shell
    // must not take somebody else's with it.
    final c = container();
    final terminal = openTerminal(c, PanelHost.preview, '/Users/me/Musiky');
    c
        .read(panelTabsProvider(PanelHost.preview).notifier)
        .open(PanelFeature.review);
    final review = c.read(panelTabsProvider(PanelHost.preview)).activeId!;

    c.read(panelTabsProvider(PanelHost.preview).notifier).close(review);

    expect(c.read(terminalSessionsProvider)[terminal], isNotNull);
  });

  test('opening tabs never ends a shell', () {
    final c = container();
    final first = openTerminal(c, PanelHost.preview, '/Users/me/Musiky');
    final second = openTerminal(c, PanelHost.preview, '/Users/me/Musiky');

    expect(c.read(terminalSessionsProvider)[first], isNotNull);
    expect(c.read(terminalSessionsProvider)[second], isNotNull);
  });
}
