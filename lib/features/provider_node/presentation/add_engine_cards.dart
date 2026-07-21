import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/chatgpt_logo.dart';
import '../../../shared/widgets/choice_card.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/api_engine_choices.dart';
import '../logic/engine_slots.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
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
/// pressed. A card the machine can't offer at all isn't drawn; one it can't
/// offer *right now* shows the reason where its button was.
class AddEngineCards extends ConsumerWidget {
  const AddEngineCards({
    super.key,
    required this.network,
    required this.serving,
  });

  final NetworkCredential network;

  /// What this machine is already serving on this grid — what rules a card out.
  final List<ServingEngine> serving;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Why this computer can't take another engine of its own right now — null
    // when it still can. On-device contention only: a grid served by hosted
    // engines alone leaves the machine free.
    final blocked = connectBlockedReason(serving);
    // Hosted engines don't hold the machine, but the built-in still can't join
    // them (ADR 0007 D4) — the middle state between "free" and "blocked".
    final localBlocked =
        blocked ??
        (serving.isEmpty
            ? null
            : 'This computer is already sharing a hosted model. The built-in '
                  'engine runs on its own — to add a local model too, run it as '
                  'a server and use “Use your own server” below.');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubscriptionCard(network: network),
        if (ref.watch(supportsBuiltInEngineProvider))
          _LocalCard(network: network, blockedReason: localBlocked),
        _ApiKeyCard(network: network, serving: serving),
        _OwnServerCard(network: network, blockedReason: blocked),
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

    final run = ref.watch(providerRunControllerProvider);
    final starting =
        run is ProviderRunActive &&
        run.grid == network.networkId &&
        run.starting;

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
        busy: starting,
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
/// Three shapes, in the order they bite: blocked by something already on this
/// machine → the reason; engine or model still missing → the set-up card, which
/// fetches both; otherwise the serve form.
class _LocalCard extends ConsumerStatefulWidget {
  const _LocalCard({required this.network, required this.blockedReason});

  final NetworkCredential network;
  final String? blockedReason;

  @override
  ConsumerState<_LocalCard> createState() => _LocalCardState();
}

class _LocalCardState extends ConsumerState<_LocalCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final blocked = widget.blockedReason;
    final caps = ref.watch(nodeCapabilitiesProvider).asData?.value;
    final needsSetup = caps != null && buildSetupPlan(caps).isNotEmpty;

    return ChoiceCard(
      icon: Icons.computer_outlined,
      title: 'Run on this computer',
      line: 'Private & offline — the model runs on your own hardware',
      action: blocked != null
          ? BlockedNote(reason: blocked)
          : SoftActionButton(
              leading: const Icon(Icons.download_rounded, size: 18),
              label: needsSetup ? 'Set it up' : 'Choose a model',
              compact: true,
              onPressed: () => setState(() => _open = true),
            ),
      footer: blocked == null && _open
          ? (needsSetup
                ? const NodeSetupCard(framed: false)
                : ServeLocalCard(network: widget.network))
          : null,
    );
  }
}

/// Paste a key from a provider the user already pays for. The key field appears
/// only once they say this is their way in.
class _ApiKeyCard extends ConsumerStatefulWidget {
  const _ApiKeyCard({required this.network, required this.serving});

  final NetworkCredential network;
  final List<ServingEngine> serving;

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
              alreadyShared: apiModelsServed(widget.serving),
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
  const _OwnServerCard({required this.network, required this.blockedReason});

  final NetworkCredential network;
  final String? blockedReason;

  @override
  ConsumerState<_OwnServerCard> createState() => _OwnServerCardState();
}

class _OwnServerCardState extends ConsumerState<_OwnServerCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final blocked = widget.blockedReason;
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
      action: blocked != null
          ? BlockedNote(reason: blocked)
          : SoftActionButton(
              leading: const Icon(Icons.link_rounded, size: 18),
              label: 'Connect',
              compact: true,
              onPressed: () => setState(() => _open = true),
            ),
      footer: blocked == null && _open
          ? ExternalServers(network: widget.network)
          : null,
    );
  }
}

/// Why a card can't act right now, in the place its button would be. A disabled
/// button would still read as something to fill in; a sentence says what to stop
/// first.
class BlockedNote extends StatelessWidget {
  const BlockedNote({super.key, required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      reason,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}
