import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_config_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import 'hermes_skill_installer.dart';
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
      await _ref.read(hermesSkillInstallerProvider).install();
    } on Object {
      // Non-fatal: the agent still chats, just without the image skill.
    }
    // Give Hermes's native web search a keyless backend, so it isn't offered a
    // `web_search` tool that silently has no provider. Fire-and-forget: the
    // install can take a moment and a chat must never wait on it — it lights up
    // for the next turn, and the `grid-web` skill covers search meanwhile.
    final setup = _ref.read(hermesAcpSetupProvider);
    if (setup != null) unawaited(setup.ensureWebSearch());
    _ref.read(hermesConfiguredProvider.notifier).set(key);
    return null;
  }

  /// Whether Hermes already has a model to answer with — its config names one,
  /// whether this app wrote it or the user did by hand. Lets a caller tell "not
  /// pointed at anything yet" (the bot would be mute) from "configured
  /// elsewhere", instead of blocking someone who set Hermes up themselves.
  Future<bool> hasModel() async {
    final model = await _config.valueAt(['model', 'default']);
    return model is String && model.trim().isNotEmpty;
  }
}
