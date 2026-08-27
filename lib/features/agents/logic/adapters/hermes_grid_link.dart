import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/relay_identity.dart';
import '../../../../infrastructure/cli/hermes_config_file.dart';
import '../../../../infrastructure/cli/hermes_cron_rearm.dart';
import '../../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../../infrastructure/cli/hermes_cron_watchdog.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../auth/logic/session_expiry_controller.dart';
import '../../../network/logic/client_app_configurator.dart';
import '../../../network/logic/client_app_detector.dart';
import '../../../network/logic/network_models_provider.dart';
import '../agent_catalog.dart';
import '../agent_model_support.dart';
import '../agent_server_error.dart';
import 'hermes_tool.dart';

/// The line shown instead of pointing Hermes at a model it can't serve — see
/// [hermesModelRefusal].
const String kHermesCannotServeSeatModel =
    "The Hermes assistant can't answer with a Claude or Codex model. Switch the "
    'assistant to Claude Code or Codex for this model, or pick a different '
    'model for Hermes.';

/// Why the Hermes assistant can't be pointed at [model], or null when it can.
///
/// *Which* models is [agentSupportsModel]'s call, not this file's: the composer
/// greys out the same ones, and a second opinion here is how a greyed row and a
/// written config end up disagreeing. This is the guard for everything that
/// doesn't go through the composer — a scheduled task, the bot — where a config
/// Hermes can't read is a failure nobody is watching for.
String? hermesModelRefusal(String model) =>
    agentSupportsModel(AgentTool.hermes, model)
    ? null
    : kHermesCannotServeSeatModel;

/// What Hermes's config was last pointed at, so we only rewrite `~/.hermes` when
/// something about the target changed. ACP reads the model from config (no
/// inline endpoint/model flag), so the config must carry the current selection.
///
/// The memo covers the grid, the model **and the credential** ([pointingKey]).
/// The token was the missing third: it rotates under the app — a sign-out and
/// sign-in on the same grid, the serve loop's refresh-on-401, `grid sync` — and
/// while the memo only knew `networkId|model`, every one of those left Hermes
/// answering with the key it had been handed hours earlier, until the app was
/// restarted. Watching [sessionProvider] is the other half: any re-read of
/// `~/.grid/credentials.toml` resets the memo, so the next message re-points
/// even if the token is unchanged and the repair passes ([HermesAuthStore]) get
/// to run again.
final hermesConfiguredProvider = NotifierProvider<HermesConfigured, String?>(
  HermesConfigured.new,
);

class HermesConfigured extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(sessionProvider);
    return null;
  }

  void set(String? key) => state = key;

  /// Forget what was written, so the next [HermesGridLink.point] rewrites the
  /// config from scratch. Called when the grid turned the assistant's key away
  /// — the config on disk is the suspect, so nothing may be taken on trust.
  void forget() => state = null;
}

/// The memo key for one (grid, model, credential) target.
///
/// The token is reduced to a short digest: this is change detection, not a
/// secret store, and the whole token in memory (and in a debugger's view of it)
/// buys nothing the first bytes of a hash don't.
String pointingKey(NetworkCredential network, String model) {
  final digest = sha256.convert(utf8.encode(network.relayApiKey));
  return '${network.networkId}|$model|${digest.toString().substring(0, 12)}';
}

/// Writes the grid Hermes should answer with into Hermes's own config.
///
/// Hermes is a separate program with its own `~/.hermes/config.yaml`: until that
/// file names a model and an endpoint, Hermes has nothing to call and every turn
/// fails. Chat did this on the way to sending a message, which left every *other*
/// way of reaching Hermes — a Telegram bot, a scheduled task — answering with a
/// config nobody had written. So it lives here, called by all of them.
final hermesGridLinkProvider = Provider<HermesGridLink>(HermesGridLink.new);

/// The grid an unattended run actually reaches ([HermesGridLink.configuredGrid]),
/// so a screen can say so when it differs from the grid on screen.
///
/// Re-read whenever the app re-points Hermes ([hermesConfiguredProvider]) — that
/// is the one event that changes the answer from inside the app; a hand-edited
/// config is picked up on the next launch.
final hermesPointedGridProvider = FutureProvider<String?>((ref) {
  ref.watch(hermesConfiguredProvider);
  return ref.watch(hermesGridLinkProvider).configuredGrid();
});

class HermesGridLink {
  HermesGridLink(this._ref, {HermesConfigFile? config})
    : _config = config ?? HermesConfigFile();

  final Ref _ref;
  final HermesConfigFile _config;

  /// Point `~/.hermes` at [network] with [model] (idempotent — only rewritten
  /// when the grid or model changed). Returns null on success, else a
  /// user-facing error line.
  Future<String?> point(NetworkCredential network, String model) async {
    // Turn a model Hermes can't serve away before touching the config. The
    // composer already greys those out, but this is the choke point every *other*
    // way of pointing Hermes goes through — a scheduled task following the
    // model, the Telegram bot — and writing the config for one takes the
    // scheduler down with it (see [_letTasksFollow]).
    final refusal = hermesModelRefusal(model);
    if (refusal != null) return refusal;
    // A credential that is already dead is not worth writing anywhere. Left to
    // run, it reaches the user as the assistant failing mid-turn on a relay 401
    // — so it hands the problem to the app's own recovery instead, which renews
    // the grid tokens from the saved session without a browser. The message
    // says "send again" because that is all the user has to do once it lands.
    if (network.isExpired(DateTime.now())) {
      unawaited(_ref.read(sessionExpiryProvider.notifier).onExpired());
      return kGridSignInStale;
    }
    final key = pointingKey(network, model);
    if (_ref.read(hermesConfiguredProvider) == key) return null;
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.hermes,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
      // The Hermes *Grid* runs, so this lands in Grid's profile. Without it the
      // app would repin the model and toolsets of the user's own `hermes` every
      // time a chat turn or a scheduled task went out.
      gridsOwnHermes: true,
    );
    if (result is ApplyError) {
      return "Couldn't point Hermes at this grid: ${result.message}";
    }
    // Top up the pieces Hermes imports only when it needs them — a keyless
    // web-search backend, the MCP SDK its connectors run on — so it isn't
    // offered tools that silently have nothing behind them. Fire-and-forget: the
    // install can take a moment and a chat must never wait on it; it lights up
    // for the next session, which is when Hermes is started again anyway.
    final setup = _ref.read(hermesAcpSetupProvider);
    if (setup != null) unawaited(setup.ensureRuntimeSupport());
    // Same idea for the scheduler's own limit: a task on this grid answers in
    // one long non-streaming turn, which Hermes's 10-minute idle watchdog reads
    // as a hung run and kills. Fire-and-forget, and a no-op after the first
    // time.
    final watchdog = _ref.read(hermesCronWatchdogProvider);
    if (watchdog != null) unawaited(watchdog.ensureLimit());
    // The model a scheduled task runs on just changed under it, and Hermes
    // fail-closes such a task rather than spending on a model nobody chose. The
    // user chose this one, here — so let the tasks follow it instead of quietly
    // dying. Fire-and-forget: pointing at a grid is on the way to a chat message
    // and must not wait on the scheduler.
    unawaited(_letTasksFollow(model));
    _ref.read(hermesConfiguredProvider.notifier).set(key);
    return null;
  }

  /// The grid turned the assistant's key away — so distrust what was written for
  /// it. The next [point] rewrites `~/.hermes` from `~/.grid`, which also re-runs
  /// the clean-up of credentials left behind for other grids ([HermesAuthStore]).
  ///
  /// This is what makes the failure self-repairing on a machine already in the
  /// broken state: nobody has to be talked through editing a hidden file, and
  /// the user's next message does it.
  void forgetPointing() {
    _ref.read(hermesConfiguredProvider.notifier).forget();
    _ref
        .read(appLogProvider)
        .warn('agent', 'grid refused the assistant key — will re-point Hermes');
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

  /// The grid `~/.hermes` answers with, as a network id — null when its config
  /// names no grid relay (a hand-written endpoint, or nothing at all).
  ///
  /// Read off the disk every time, never remembered: the config outlives the
  /// app. The scheduler is a daemon of Hermes's own, so tonight's task runs
  /// against whatever was written here in some earlier session — which is not
  /// always the grid the window is showing, and was invisible until this.
  /// A config too broken to parse counts as naming no grid, rather than
  /// throwing: the only caller wants a name to put in a sentence, and Riverpod
  /// answers a thrown future by calling this ten more times.
  Future<String?> configuredGrid() async {
    try {
      final base = await _config.valueAt(['model', 'base_url']);
      return base is String ? gridIdFromRelayBase(base) : null;
    } on Object {
      return null;
    }
  }

  /// Whether Hermes already has a model it can actually answer with. Lets a
  /// caller tell "not pointed at anything yet" (the bot would be mute) from
  /// "configured elsewhere", instead of blocking someone who set Hermes up
  /// themselves.
  ///
  /// A config naming a model Hermes can't serve counts as **no** model, not as
  /// one: 03/08 the config still named a `claude:*` seat from before the pairing
  /// was blocked, and every scheduled run went to it — each ended with the tool
  /// call typed out as the report, and was recorded as `ok`.
  Future<bool> hasModel() async {
    final model = await configuredModel();
    return model != null && hermesModelRefusal(model) == null;
  }

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
    final (:model, :servesAnything) = await _modelForGrid(grid.networkId);
    if (model == null) {
      if (await hasModel()) return null;
      // Two different problems, and telling the user the wrong one costs them
      // the fix: an empty grid needs a model shared on it, a grid of CLI seats
      // needs another assistant.
      if (servesAnything) {
        return 'This grid only shares AI that Claude Code or Codex answers, so '
            'the Hermes assistant has nothing to run on here. Switch the '
            'assistant, or share a model on this computer '
            '($kShareModelsPlace).';
      }
      return "This grid isn't sharing any AI yet, so the assistant would have "
          'nothing to answer with. Start sharing on this computer '
          '($kShareModelsPlace), then try again.';
    }
    return point(grid, model);
  }

  /// The model to answer [networkId] with — the one the user last chatted with
  /// when the grid still serves it, else the first the grid serves — alongside
  /// whether the grid serves anything at all.
  ///
  /// Only models Hermes can answer with are candidates: a CLI seat on this grid
  /// is another vendor's agent behind the relay (see [hermesModelRefusal]), and
  /// this picks for runs nobody is watching. [servesAnything] is what separates
  /// "nothing shared here" from "nothing *Hermes* can use here" for the caller's
  /// message.
  Future<({String? model, bool servesAnything})> _modelForGrid(
    String networkId,
  ) async {
    final served = await _ref.read(networkModelsForProvider(networkId).future);
    final usable = [
      for (final model in served)
        if (agentSupportsModel(AgentTool.hermes, model)) model,
    ];
    if (usable.isEmpty) {
      return (model: null, servesAnything: served.isNotEmpty);
    }
    final chosen = _ref.read(chatPrefsProvider).model;
    return (
      model: usable.contains(chosen) ? chosen : usable.first,
      servesAnything: true,
    );
  }
}
