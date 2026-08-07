import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import 'terminal_session.dart';

/// The terminals the app has open, one per panel tab that asked for one.
@immutable
class TerminalSessionsState {
  TerminalSessionsState({Map<String, TerminalSession> sessions = const {}})
    : sessions = Map.unmodifiable(sessions);

  /// Keyed by the id of the tab that owns the terminal.
  final Map<String, TerminalSession> sessions;

  /// The terminal belonging to [tabId], or null before it has been opened.
  TerminalSession? operator [](String tabId) => sessions[tabId];
}

/// How a session's shell is started.
typedef ShellStarter =
    void Function(
      TerminalSession session,
      void Function(Object error, StackTrace stack) onError,
    );

/// The seam between the tab bookkeeping and the pty behind it.
///
/// One implementation in the app, and it does the obvious thing. It exists so
/// that a test of "which terminals are still alive" can run without spawning a
/// real shell per case — the tests here are offline and deterministic, and a
/// login shell is neither.
final shellStarterProvider = Provider<ShellStarter>(
  (ref) =>
      (session, onError) => session.start(onError: onError),
);

/// Every open terminal, keyed by the tab it lives in.
///
/// **A terminal belongs to its tab, not to a folder.** Two Terminal tabs are two
/// shells even in the same project — running a server in one and working in the
/// other is the normal case — and the tab strip above already answers "which
/// one am I looking at". What a tab does *not* survive is being closed: see
/// [reap].
///
/// **The folder is fixed when the tab opens.** A running shell can't be moved —
/// `cd` is the user's to type — so a tab started in one project keeps saying so
/// in its toolbar rather than quietly claiming to be somewhere else once the
/// conversation moves on.
///
/// Not auto-disposed: switching to another tab must not kill the build running
/// in this one. The shells end when their tab closes, or when the app does.
final terminalSessionsProvider =
    NotifierProvider<TerminalSessions, TerminalSessionsState>(
      TerminalSessions.new,
    );

class TerminalSessions extends Notifier<TerminalSessionsState> {
  /// The sessions themselves, held here rather than read back off [state]:
  /// killing the shells happens in `onDispose`, and Riverpod forbids touching
  /// `state` from a life-cycle callback.
  final Map<String, TerminalSession> _sessions = {};

  @override
  TerminalSessionsState build() {
    ref.onDispose(_disposeAll);
    return _snapshot();
  }

  /// Opens the terminal for [tabId] in [workdir], or leaves the one already
  /// running there alone. Safe to call on every build of the tab's view.
  void ensure({required String tabId, required String workdir}) {
    if (_sessions.containsKey(tabId)) return;
    final session = TerminalSession(
      id: tabId,
      workdir: workdir,
      onChanged: _publish,
    );
    _sessions[tabId] = session;
    ref.read(shellStarterProvider)(session, _logStartFailure);
    _publish();
  }

  /// Ends the terminal that lived in [tabId], if there was one.
  ///
  /// Closing a tab has to close the shell in it: an orphaned pty holds a
  /// process the user can no longer see, let alone stop. Called by whoever
  /// closes the tab — a terminal has no business knowing what a panel is.
  void endSession(String tabId) {
    final gone = _sessions.remove(tabId);
    if (gone == null) return;
    gone.dispose();
    _publish();
  }

  /// Opens a new shell in a terminal whose last one ended.
  void restart(String tabId) =>
      _sessions[tabId]?.restart(onError: _logStartFailure);

  void _logStartFailure(Object error, StackTrace stack) {
    ref
        .read(appLogProvider)
        .failure(
          'terminal',
          'Could not start a shell',
          error: error,
          stackTrace: stack,
        );
  }

  /// Publishes what the panels should now show.
  ///
  /// Always a fresh state object, even when only a session's own status moved
  /// (a shell started, died, or failed to open): the status lives on the
  /// session, and a notifier handed back the object it already holds tells its
  /// listeners nothing changed.
  void _publish() => state = _snapshot();

  TerminalSessionsState _snapshot() =>
      TerminalSessionsState(sessions: _sessions);

  void _disposeAll() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
