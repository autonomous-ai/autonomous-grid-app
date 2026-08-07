import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/terminal/logic/terminal_sessions_controller.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        // No real shell: these cover which terminals are alive, and spawning a
        // login shell per case would make them slow and machine-dependent for
        // nothing.
        shellStarterProvider.overrideWithValue((session, onError) {}),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  TerminalSessionsState stateOf(ProviderContainer c) =>
      c.read(terminalSessionsProvider);

  TerminalSessions sessionsOf(ProviderContainer c) =>
      c.read(terminalSessionsProvider.notifier);

  test('a tab gets a terminal in the folder the chat is about', () {
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/Musiky');

    expect(stateOf(c)['tab-1']?.workdir, '/Users/me/Musiky');
  });

  test('re-opening the same tab keeps the shell that is already running', () {
    // The view calls this on every build, and a second call must not replace a
    // terminal mid-command — its scrollback and whatever is running in it are
    // the whole reason the session outlives the widget.
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/Musiky');
    final first = stateOf(c)['tab-1'];
    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/Musiky');

    expect(stateOf(c)['tab-1'], same(first));
  });

  test('two tabs on one folder are two shells, not one shared', () {
    // Running a server in one and working in the other is the normal case.
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/Musiky');
    sessionsOf(c).ensure(tabId: 'tab-2', workdir: '/Users/me/Musiky');

    expect(stateOf(c).sessions, hasLength(2));
    expect(stateOf(c)['tab-1'], isNot(same(stateOf(c)['tab-2'])));
  });

  test('a tab that stays open keeps its folder when the chat moves on', () {
    // A running shell can't be moved — `cd` is the user's to type — so the tab
    // has to keep saying where it actually is.
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/Musiky');
    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/Users/me/bubu');

    expect(stateOf(c)['tab-1']?.workdir, '/Users/me/Musiky');
  });

  test('ending a tab kills its shell and leaves the others alone', () {
    // An orphaned pty holds a process the user can no longer see, let alone
    // stop.
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/a/one');
    sessionsOf(c).ensure(tabId: 'tab-2', workdir: '/b/two');
    sessionsOf(c).endSession('tab-1');

    expect(stateOf(c).sessions.keys, ['tab-2']);
  });

  test('ending a tab that never had a terminal changes nothing', () {
    // Every tab reports itself closed, including Review and Files.
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/a/one');
    final before = stateOf(c);
    sessionsOf(c).endSession('review-tab-9');

    expect(stateOf(c), same(before));
  });

  test('ending the last tab leaves no terminals behind', () {
    final c = container();

    sessionsOf(c).ensure(tabId: 'tab-1', workdir: '/a/one');
    sessionsOf(c).endSession('tab-1');

    expect(stateOf(c).sessions, isEmpty);
  });
}
