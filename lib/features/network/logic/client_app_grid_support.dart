import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import 'client_app_detector.dart';
import 'grid_overview_provider.dart';

/// The wire dialect a client speaks to a grid's relay.
///
/// The relay answers three, and a client only ever speaks one: an
/// OpenAI-compatible app posts to `/v1/chat/completions`, Codex to
/// `/v1/responses`, Claude Code to Anthropic's `/v1/messages`. The overview
/// reports one flag per dialect, so which apps a grid can serve is a lookup, not
/// a guess.
enum RelayDialect { chatCompletions, responses, messages }

/// The dialect [app] needs the grid to answer on.
///
/// Hermes counts as chat-completions: it speaks the Responses API too, but only
/// when the model it's pointed at requires it (`api_mode: responses` on a named
/// provider — see `hermesConfigSnippet`), so a chat grid is enough for it to run.
RelayDialect clientDialect(ClientApp app) => switch (app) {
  ClientApp.claudeCode => RelayDialect.messages,
  ClientApp.codex => RelayDialect.responses,
  ClientApp.hermes ||
  ClientApp.openClaw ||
  ClientApp.buzz => RelayDialect.chatCompletions,
};

/// What [overview] says about [dialect] — true/false when the relay reports it,
/// null when it didn't (an older relay, or no overview yet).
bool? gridAdvertises(RelayDialect dialect, GridOverview? overview) =>
    switch (dialect) {
      RelayDialect.chatCompletions => overview?.advertisesChatCompletions,
      RelayDialect.responses => overview?.advertisesResponses,
      RelayDialect.messages => overview?.advertisesMessages,
    };

/// Whether a grid described by [overview] can answer [app] at all.
///
/// Null reads as **"let it try"**, never as "no" — the flag is null while the
/// overview loads, when it fails, and on every relay that doesn't ship the flag
/// yet. Only an explicit `false` rules the app out, which is the one case where
/// walking someone through five setup steps would end in a connection error.
bool clientRunsOnGrid(ClientApp app, GridOverview? overview) =>
    gridAdvertises(clientDialect(app), overview) != false;

/// Why an app can't be used on the open grid, in the user's terms — no wire
/// dialects, no endpoint names, just the fact that decides it. Shared with the
/// Agents list (`agentUnsupportedHere`) so the two screens state it in one
/// wording.
String appUnsupportedHere(String appName) =>
    "This grid doesn't serve a model $appName can talk to.";

/// Whether the grid selected right now can answer [app].
///
/// A grid-level answer from a grid-level flag: it says the grid serves *a* model
/// this app can talk to, not that the model in the config is that one — a
/// mismatch there surfaces as the app's own failure, not as a guess up front.
final clientRunsOnGridProvider = Provider.autoDispose.family<bool, ClientApp>(
  (ref, app) => clientRunsOnGrid(app, ref.watch(gridOverviewSnapshot)),
);
