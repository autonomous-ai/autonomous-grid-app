import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_session_service.dart';
import 'hermes_tool.dart';

/// The seam onto Hermes's session store, or null when the agent isn't installed
/// (that computer's chats are answered by the grid's API, which names nothing).
final hermesSessionServiceProvider = Provider<HermesSessionService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesSessionServiceImpl(path);
});

/// How long the app keeps asking for the chat's name, and how it spaces the
/// asks. The agent writes the name a few seconds after its first reply (it asks
/// a model for it in the background), so the first look almost always comes up
/// empty — these waits add up to ~12s, after which the chat simply keeps the
/// name derived from its first message.
const List<Duration> kAgentTitleRetries = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 3),
  Duration(seconds: 3),
];

/// Overridable so tests don't sit through the real waits.
final agentTitleRetriesProvider = Provider<List<Duration>>(
  (ref) => kAgentTitleRetries,
);

/// Asks the agent what it called a chat.
abstract interface class AgentSessionTitle {
  /// The name the agent gave [sessionId], waiting out the delay before it writes
  /// one. Null when the agent never named it (or isn't installed) — the caller
  /// then keeps the name it already had rather than blanking the chat.
  Future<String?> waitFor(String sessionId);
}

final agentSessionTitleProvider = Provider<AgentSessionTitle>(
  AgentSessionTitleImpl.new,
);

class AgentSessionTitleImpl implements AgentSessionTitle {
  const AgentSessionTitleImpl(this._ref);

  final Ref _ref;

  @override
  Future<String?> waitFor(String sessionId) async {
    final sessions = _ref.read(hermesSessionServiceProvider);
    if (sessions == null) return null;

    for (final wait in _ref.read(agentTitleRetriesProvider)) {
      await Future<void>.delayed(wait);
      final title = await sessions.title(sessionId);
      if (title != null) return title;
    }
    return null;
  }
}
