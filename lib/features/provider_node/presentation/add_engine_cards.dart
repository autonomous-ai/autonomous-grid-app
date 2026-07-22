import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/chatgpt_logo.dart';
import '../../../shared/widgets/choice_card.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/api_engine_choices.dart';
import '../logic/provider_run_controller.dart';
import 'api_engine_block.dart';
import 'external_servers.dart';

/// The ways to put a model on this grid from this computer — the same cards, in
/// the same words, as the first-run screen.
///
/// This used to be a row of pills (Cloud / This computer / Your own server) over
/// one permanently-open form. Two problems: you had to open a tab before you
/// could see what was behind it, so comparing the three meant three clicks; and
/// the open form put a provider dropdown, a model dropdown and four lines of
/// small print in front of a decision the user hadn't made yet. Meanwhile the
/// first-run screen asked the very same question with a title, a line and a
/// button per option — and called them different things, so nobody could tell
/// the two screens were about one choice.
///
/// So: one card per way in, the form revealed inside the card once its button is
/// pressed. A card the machine can't offer at all isn't drawn; whether this
/// computer has room for an engine at all is the page's call, not a card's —
/// these are shown only when it does.
class AddEngineCards extends ConsumerWidget {
  const AddEngineCards({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No per-card "you can't right now" reasons here: this computer shares one
    // engine at a time, so the page shows these cards only while nothing is
    // serving (see `_addEngineBlocks`). Every card can act.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubscriptionCard(network: network),
        if (ref.watch(supportsBuiltInEngineProvider))
          _LocalCard(network: network),
        _ApiKeyCard(network: network),
        _OwnServerCard(network: network),
      ],
    );
  }
}

/// Sign in with a ChatGPT subscription — nothing to download, no key to find, so
/// it leads. Hidden when the installed CLI whitelists no sign-in provider.
class _SubscriptionCard extends ConsumerWidget {
  const _SubscriptionCard({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = signInEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const [],
    );
    if (engines.isEmpty) return const SizedBox.shrink();
    final provider = engines.first.provider;

    // No busy state on this button. It used to spin whenever *any* join was
    // starting — press "Choose a model" for a local one and this card claimed a
    // ChatGPT sign-in was under way. The starting card above owns that state,
    // and these cards leave the page the moment a join begins.
    return ChoiceCard(
      icon: Icons.auto_awesome_outlined,
      title: 'Continue with ChatGPT',
      line: 'Fastest setup — sign in with your subscription',
      // The vendor's own mark: this hands a ChatGPT account over, so it reads as
      // their sign-in rather than one of ours.
      action: SoftActionButton(
        leading: const ChatGptLogo(size: 18),
        label: 'Sign in',
        compact: true,
        onPressed: () => ref
            .read(providerRunControllerProvider.notifier)
            .startApiEngine(
              network: network.networkId,
              kind: provider.kind,
              envVar: provider.envVar,
              apiKey: '',
            ),
      ),
    );
  }
}

/// Run a downloaded model here with the built-in engine.
///
/// Two shapes: engine or model still missing → one press sets both up, with the
/// progress underneath; otherwise the serve form.
class _LocalCard extends ConsumerStatefulWidget {
  const _LocalCard({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_LocalCard> createState() => _LocalCardState();
}

class _LocalCardState extends ConsumerState<_LocalCard> {
  bool _open = false;

  /// Fetch whatever this computer is missing — the engine, a model, or both.
  ///
  /// Runs the plan on the press rather than previewing it behind a second
  /// button: the card above already says what this option is and what it costs
  /// ("downloads a model"), so a plan listing the same two steps under a "Set up
  /// now" button was the same decision asked twice. The steps still show, as
  /// progress, once it's under way.
  Future<void> _setUp() async {
    final caps = await ref.read(nodeCapabilitiesProvider.future);
    if (!mounted) return;
    // Leave the serve form open behind it, so the moment the download lands the
    // card is showing the model picker rather than a finished progress list.
    setState(() => _open = true);
    await ref
        .read(nodeSetupControllerProvider.notifier)
        .run(buildSetupPlan(caps));
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(nodeCapabilitiesProvider).asData?.value;
    final needsSetup = caps != null && buildSetupPlan(caps).isNotEmpty;
    final setup = ref.watch(nodeSetupControllerProvider);

    return ChoiceCard(
      icon: Icons.computer_outlined,
      title: 'Run on this computer',
      line: 'Private & offline — the model runs on your own hardware',
      action: SoftActionButton(
        leading: const Icon(Icons.download_rounded, size: 18),
        label: needsSetup ? 'Set it up' : 'Choose a model',
        compact: true,
        busy: setup is NodeSetupRunning,
        onPressed: needsSetup ? _setUp : () => setState(() => _open = true),
      ),
      footer: _footer(needsSetup, setup),
    );
  }

  /// What sits under the button: the setup's own progress while there is one to
  /// show, else the serve form once the user has asked for it. An untouched
  /// setup shows nothing — that state is the button.
  Widget? _footer(bool needsSetup, NodeSetupState setup) {
    if (needsSetup) {
      return setup is NodeSetupIdle ? null : const NodeSetupCard(framed: false);
    }
    return _open ? ServeLocalCard(network: widget.network) : null;
  }
}

/// Paste a key from a provider the user already pays for. The key field appears
/// only once they say this is their way in.
class _ApiKeyCard extends ConsumerStatefulWidget {
  const _ApiKeyCard({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends ConsumerState<_ApiKeyCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = keyEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();

    return ChoiceCard(
      icon: Icons.key_outlined,
      title: 'Use an API key',
      line: apiKeyCardLine(available),
      action: SoftActionButton(
        leading: const Icon(Icons.vpn_key_outlined, size: 18),
        label: 'Enter a key',
        compact: true,
        onPressed: () => setState(() => _open = true),
      ),
      footer: _open
          ? ApiEngineForm(
              network: widget.network,
              engines: engines,
              compact: true,
            )
          : null,
    );
  }
}

/// Share an OpenAI-compatible engine the user already runs here (Ollama,
/// llama-server). Opening it lists what was detected on this machine, so the
/// common case is one tap rather than typing a URL.
class _OwnServerCard extends ConsumerStatefulWidget {
  const _OwnServerCard({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_OwnServerCard> createState() => _OwnServerCardState();
}

class _OwnServerCardState extends ConsumerState<_OwnServerCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    // Named on the card, not hidden inside it: a running Ollama is the whole
    // reason to open this, and the pill it replaced carried the same count.
    final detected =
        ref
            .watch(backendsProvider)
            .asData
            ?.value
            .where((b) => b.isExternal)
            .length ??
        0;

    return ChoiceCard(
      icon: Icons.dns_outlined,
      title: 'Use your own server',
      line: detected > 0
          ? 'Found $detected on this computer — share one as it is'
          : 'Point Grid at an engine you already run here',
      action: SoftActionButton(
        leading: const Icon(Icons.link_rounded, size: 18),
        label: 'Connect',
        compact: true,
        onPressed: () => setState(() => _open = true),
      ),
      footer: _open ? ExternalServers(network: widget.network) : null,
    );
  }
}
