import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_config_file.dart';
import '../../../infrastructure/cli/hermes_cron_rearm.dart';
import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import '../../network/logic/network_models_provider.dart';
import '../../agents/logic/agent_catalog.dart';
import 'agent_skill_installer.dart';
import 'hermes_tool.dart';

/// The `networkId|model` Hermes's config was last pointed at, so we only rewrite
/// `~/.hermes` when the target grid or model changes. ACP reads the model from
/// config (no inline endpoint/model flag), so the config must carry the current
/// selection.
final hermesConfiguredProvider = NotifierProvider<HermesConfigured, String?>(
  HermesConfigured.new,
);

class HermesConfigured extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? key) => state = key;
}

/// Writes the grid Hermes should answer with into Hermes's own config.
///
/// Hermes is a separate program with its own `~/.hermes/config.yaml`: until that
/// file names a model and an endpoint, Hermes has nothing to call and every turn
/// fails. Chat did this on the way to sending a message, which left every *other*
/// way of reaching Hermes — a Telegram bot, a scheduled task — answering with a
/// config nobody had written. So it lives here, called by all of them.
final hermesGridLinkProvider = Provider<HermesGridLink>(HermesGridLink.new);

class HermesGridLink {
  HermesGridLink(this._ref, {HermesConfigFile? config})
    : _config = config ?? HermesConfigFile();

  final Ref _ref;
  final HermesConfigFile _config;

  /// Point `~/.hermes` at [network] with [model] (idempotent — only rewritten
  /// when the grid or model changed). Returns null on success, else a
  /// user-facing error line.
  Future<String?> point(NetworkCredential network, String model) async {
    // Every model the grid serves is written here, responses-only ones included:
    // those get a named provider carrying `api_mode: codex_responses`, which is
    // how Hermes speaks that dialect. A build too old to resolve that provider
    // fails the turn with its own words, humanized where the failure lands
    // ([friendlyAgentUnknownProvider]) — the app used to refuse the model up
    // front instead, which spent everyone's Codex models on one old build.
    final key = '${network.networkId}|$model';
    if (_ref.read(hermesConfiguredProvider) == key) return null;
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.hermes,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
    );
    if (result is ApplyError) {
      return "Couldn't point Hermes at this grid: ${result.message}";
    }
    // Give the agent the grid's skills (image generation). Credential-free — the
    // skill reads the endpoint/key from the `.env` just written. A skill-install
    // hiccup must not block chatting, so its failure is swallowed here.
    try {
      await _ref.read(agentSkillInstallerProvider).install(AgentTool.hermes);
    } on Object {
      // Non-fatal: the agent still chats, just without the image skill.
    }
    // Give Hermes's native web search a keyless backend, so it isn't offered a
    // `web_search` tool that silently has no provider. Fire-and-forget: the
    // install can take a moment and a chat must never wait on it — it lights up
    // for the next turn, and the `grid-web` skill covers search meanwhile.
    final setup = _ref.read(hermesAcpSetupProvider);
    if (setup != null) unawaited(setup.ensureWebSearch());
    // The model a scheduled task runs on just changed under it, and Hermes
    // fail-closes such a task rather than spending on a model nobody chose. The
    // user chose this one, here — so let the tasks follow it instead of quietly
    // dying. Fire-and-forget: pointing at a grid is on the way to a chat message
    // and must not wait on the scheduler.
    unawaited(_letTasksFollow(model));
    _ref.read(hermesConfiguredProvider.notifier).set(key);
    return null;
  }

  /// Re-arm the saved tasks against [model]. Best-effort by design: a task that
  /// can't be re-armed still says so on its own screen (with a button to retry),
  /// so a hiccup here must not fail the thing the user actually asked for — but
  /// it is logged, because "my tasks stopped running" is otherwise invisible.
  Future<void> _letTasksFollow(String model) async {
    final cron = _ref.read(hermesCronServiceProvider);
    if (cron == null) return;
    final log = _ref.read(appLogProvider);
    try {
      final rearmed = await cron.followModel(model);
      if (rearmed.isEmpty) return;
      log.info(
        'tasks',
        're-armed ${rearmed.length} scheduled task(s) on $model: '
            '${rearmed.join(', ')}',
      );
    } on CronRearmException catch (error) {
      log.failure('tasks', "couldn't re-arm scheduled tasks: ${error.message}");
    }
  }

  /// The model Hermes answers with, whether this app wrote it or the user did by
  /// hand — null when its config names none. What an unattended surface has to
  /// run on, so a scheduled task can be told which model it's about to use.
  Future<String?> configuredModel() async {
    final model = await _config.valueAt(['model', 'default']);
    if (model is! String) return null;
    final trimmed = model.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Whether Hermes already has a model to answer with. Lets a caller tell "not
  /// pointed at anything yet" (the bot would be mute) from "configured
  /// elsewhere", instead of blocking someone who set Hermes up themselves.
  Future<bool> hasModel() async => await configuredModel() != null;

  /// Point Hermes at whatever grid the app has selected, resolving a model for
  /// it, so an unattended surface can actually answer. Returns null when Hermes
  /// is ready — including when it was already configured by an earlier chat or
  /// by hand — else a user-facing line naming what to fix.
  ///
  /// A scheduled task fires at 8am and a chat-platform bot answers a stranger's
  /// message: both run with nobody there to pick a model. Until Hermes's own
  /// config names one, every such run fails with a raw "no model configured".
  /// Writing the selected grid here, before the task is saved or the bot goes
  /// live, is what stops that — so both the scheduler and the platforms share
  /// this one path rather than each pointing Hermes their own way.
  Future<String?> ensureModelForSelectedGrid() async {
    final grid = _ref.read(selectedNetworkProvider);
    if (grid == null) {
      // Already configured (by hand, or an earlier chat) — leave it be rather
      // than refusing over a grid we only wanted for setup.
      if (await hasModel()) return null;
      return 'Pick a grid in Chat first — the assistant answers with that '
          "grid, and there's no answer without one.";
    }
    final model = await _modelForGrid(grid.networkId);
    if (model == null) {
      if (await hasModel()) return null;
      return "This grid isn't sharing any AI yet, so the assistant would have "
          'nothing to answer with. Start sharing on this computer (Settings ▸ '
          'This computer), then try again.';
    }
    return point(grid, model);
  }

  /// The model to answer [networkId] with: the one the user last chatted with
  /// when the grid still serves it, else whatever that grid serves first. Null
  /// when the grid serves nothing at all.
  Future<String?> _modelForGrid(String networkId) async {
    final served = await _ref.read(networkModelsForProvider(networkId).future);
    if (served.isEmpty) return null;
    final chosen = _ref.read(chatPrefsProvider).model;
    return served.contains(chosen) ? chosen : served.first;
  }
}
