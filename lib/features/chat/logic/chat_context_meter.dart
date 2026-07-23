import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../playground/logic/context_usage.dart';
import 'chat_sessions_controller.dart';
import 'conversation.dart';

/// How full the open chat's context window is, or null when there's nothing
/// honest to show — the composer's ring hides on null.
///
/// Two things have to be true for a ring to mean anything: a count, and a
/// window to count against. The count comes from whoever answered (Hermes
/// reports it over ACP, Codex and the relay report their token usage) and falls
/// back to counting the transcript here. The window comes from the reporter
/// when it named one, else from what the grid advertises for the model. When
/// neither knows the window, this returns null rather than filling a ring
/// against a number nobody stands behind.
final activeChatContextProvider = Provider.autoDispose<ContextUsage?>((ref) {
  final active = ref.watch(chatSessionsProvider.select((s) => s.active));
  if (active == null) return null;
  final grid = ref.watch(selectedNetworkProvider);
  final overview = grid == null
      ? const AsyncValue<GridOverview>.loading()
      : ref.watch(gridOverviewForProvider(grid.networkId));
  return chatContextUsage(
    active,
    advertisedWindow: advertisedContextWindow(overview, active.model),
  );
});

/// The context length the grid advertises for [model], or null while the
/// overview is loading, offline, or simply doesn't publish one. Only an
/// explicit, positive number counts — a relay that omits the field must not be
/// read as "zero".
int? advertisedContextWindow(AsyncValue<GridOverview> overview, String model) {
  final models = overview.asData?.value.models ?? const <OverviewModel>[];
  for (final entry in models) {
    if (entry.id != model) continue;
    final length = entry.contextLength;
    return length != null && length > 0 ? length : null;
  }
  return null;
}

/// What to show for [conversation], given the window its grid advertises.
///
/// Pure so the fallbacks are unit-tested: a chat nobody counted still gets a
/// ring from the transcript's own size (flagged [ContextUsage.estimated]), an
/// empty chat gets none, and no window at all means no ring.
ContextUsage? chatContextUsage(
  Conversation conversation, {
  required int? advertisedWindow,
}) {
  if (conversation.messages.isEmpty) return null;
  final limit = conversation.contextLimit ?? advertisedWindow;
  if (limit == null || limit <= 0) return null;
  final reported = conversation.contextTokens;
  return ContextUsage(
    usedTokens: reported ?? estimateConversationTokens(conversation.messages),
    limitTokens: limit,
    estimated: reported == null,
  );
}
