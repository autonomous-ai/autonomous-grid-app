import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/choice_row.dart';
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

/// The ways to put a model on this grid from this computer — one pressable row
/// each, in one surface, the form opening under the row that offers it.
///
/// This has been three shapes. A row of pills (Cloud / This computer / Your own
/// server) over one permanently-open form: you had to open a tab to see what was
/// behind it, and the open form put two dropdowns and four lines of small print
/// in front of a decision nobody had made. Then a card each — a title, a line
/// and a button — which fixed the comparing but spent ~600px on four options,
/// every one at identical weight, with the real target a small button inside
/// each card whose label mostly repeated the title above it ("Use an API key" →
/// Enter a key).
///
/// So: rows. The whole row is the target, which lets the button go; the options
/// cost a third of the height; and the hairlines say these are answers to one
/// question rather than a list to get through. The first-run screen
/// offers the same rows, but one surface each — there the choice *is* the
/// screen, and two separated targets read as two choices rather than a list.
///
/// A row the machine can't offer at all isn't drawn; whether this computer has
/// room for an engine is the page's call, not a row's — these are shown only
/// when it does.
class AddEngineOptions extends ConsumerWidget {
  const AddEngineOptions({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No per-row "you can't right now" reasons here: this computer shares one
    // engine at a time, so the page shows these only while nothing is serving
    // (see `_addEngineBlocks`). Every row can act.
    return ChoiceRowGroup(
      children: [
        ..._seatRows(ref),
        if (ref.watch(supportsBuiltInEngineProvider))
          _LocalRow(network: network),
        ?_ApiKeyRow.forCatalog(ref, network),
        _OwnServerRow(network: network),
      ],
    );
  }

  /// A row per coding CLI already signed in on this computer (Claude Code,
  /// Codex CLI) — nothing to download and no key to find, so they lead. Empty on
  /// a machine with none of them, so the group never offers a road it can't
  /// walk.
  ///
  /// One row each, not one row naming both: the joined row started whichever CLI
  /// was found first, so a user with two of them could only share the other by
  /// finding the dropdown in the Cloud Provider block further down the page.
  List<Widget> _seatRows(WidgetRef ref) => [
    for (final engine in seatEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const [],
    ))
      _seatRow(ref, engine.provider),
  ];

  /// One seat's row. It carries no busy state — the starting card above owns
  /// that, and these rows leave the page the moment a join begins.
  ChoiceRow _seatRow(WidgetRef ref, ApiProvider provider) => ChoiceRow(
    icon: const Icon(Icons.terminal_outlined),
    title: seatRowTitle(provider),
    line: 'Already installed and signed in — nothing to set up',
    action: ChoiceRowAction.open,
    onPressed: () => ref
        .read(providerRunControllerProvider.notifier)
        .startApiEngine(
          network: network.networkId,
          provider: provider,
          apiKey: '',
        ),
  );
}

/// Run a downloaded model here with the built-in engine.
///
/// Two shapes: engine or model still missing → one press sets both up, with the
/// progress underneath; otherwise the serve form.
class _LocalRow extends ConsumerStatefulWidget {
  const _LocalRow({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_LocalRow> createState() => _LocalRowState();
}

class _LocalRowState extends ConsumerState<_LocalRow> {
  bool _open = false;

  /// Fetch whatever this computer is missing — the engine, a model, or both.
  ///
  /// Runs the plan on the press rather than previewing it behind a second
  /// button: the row already says what this option is and that it installs
  /// first, so a plan listing the same two steps under a "Set up now" button was
  /// the same decision asked twice. The steps still show, as progress, once it's
  /// under way.
  Future<void> _setUp() async {
    final caps = await ref.read(nodeCapabilitiesProvider.future);
    if (!mounted) return;
    // Leave the serve form open behind it, so the moment the download lands the
    // row is showing the model picker rather than a finished progress list.
    setState(() => _open = true);
    await ref
        .read(nodeSetupControllerProvider.notifier)
        .run(buildSetupPlan(caps));
  }

  /// A press sets the machine up when it still needs it, and otherwise just
  /// opens and closes the form. Setting up is deliberately not a toggle: folding
  /// a running install away would hide the only progress there is.
  void _press(bool needsSetup, NodeSetupState setup) {
    if (needsSetup && setup is NodeSetupIdle) {
      _setUp();
      return;
    }
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(nodeCapabilitiesProvider).asData?.value;
    final needsSetup = caps != null && buildSetupPlan(caps).isNotEmpty;
    final setup = ref.watch(nodeSetupControllerProvider);
    final body = _body(setup);

    return ChoiceRow(
      icon: const Icon(Icons.computer_outlined),
      title: 'Run on this computer',
      // What the press will actually do, when it isn't the obvious one. Without
      // this, a machine with no engine yet answers a press for a model picker
      // with an install — the old card said so on its button ("Set it up"), and
      // rows have no button to say it on.
      line: needsSetup
          ? 'Private & offline — installs the engine first'
          : 'Private & offline — the model runs on your own hardware',
      action: ChoiceRowAction.open,
      expanded: body != null,
      onPressed: () => _press(needsSetup, setup),
      child: body,
    );
  }

  /// What sits under the row: the setup's own progress while there is one to
  /// show, else the serve form once the user has asked for it. An untouched
  /// setup shows nothing — that state is the row itself.
  ///
  /// A *finished* run shows nothing either. The press was for the form behind
  /// the install, not for a receipt: parking a "Done — this computer is set up
  /// as a node" checklist here leaves the user reading a summary of what they
  /// already watched happen, with a Done button as the only way on. A failure
  /// still keeps its card, because that card carries the retry.
  Widget? _body(NodeSetupState setup) {
    final content = switch (setup) {
      NodeSetupRunning() ||
      NodeSetupFailed() => const NodeSetupCard(framed: false),
      NodeSetupIdle() ||
      NodeSetupDone() => _open ? ServeLocalCard(network: widget.network) : null,
    };
    return content == null ? null : _RowBody(child: content);
  }
}

/// Paste a key from a provider the user already pays for. The key field appears
/// only once they say this is their way in.
class _ApiKeyRow extends ConsumerStatefulWidget {
  const _ApiKeyRow({required this.network, required this.engines});

  final NetworkCredential network;
  final List<ApiEngine> engines;

  /// The row, or null when the installed CLI whitelists no key provider — the
  /// list is read here rather than inside the state so the group can leave the
  /// row out entirely instead of drawing an empty one.
  static _ApiKeyRow? forCatalog(WidgetRef ref, NetworkCredential network) {
    final engines = keyEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const [],
    );
    return engines.isEmpty
        ? null
        : _ApiKeyRow(network: network, engines: engines);
  }

  @override
  ConsumerState<_ApiKeyRow> createState() => _ApiKeyRowState();
}

class _ApiKeyRowState extends ConsumerState<_ApiKeyRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    return ChoiceRow(
      icon: const Icon(Icons.key_outlined),
      title: 'Use an API key',
      line: apiKeyCardLine(available),
      action: ChoiceRowAction.open,
      expanded: _open,
      onPressed: () => setState(() => _open = !_open),
      child: _open
          ? _RowBody(
              child: ApiEngineForm(
                network: widget.network,
                engines: widget.engines,
                compact: true,
              ),
            )
          : null,
    );
  }
}

/// Share an OpenAI-compatible engine the user already runs here (Ollama,
/// llama-server). Opening it lists what was detected on this machine, so the
/// common case is one tap rather than typing a URL.
class _OwnServerRow extends ConsumerStatefulWidget {
  const _OwnServerRow({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_OwnServerRow> createState() => _OwnServerRowState();
}

class _OwnServerRowState extends ConsumerState<_OwnServerRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    // Named on the row, not hidden inside it: a running Ollama is the whole
    // reason to open this, and the pill it replaced carried the same count.
    final detected =
        ref
            .watch(backendsProvider)
            .asData
            ?.value
            .where((b) => b.isExternal)
            .length ??
        0;

    return ChoiceRow(
      icon: const Icon(Icons.dns_outlined),
      title: 'Use your own server',
      line: detected > 0
          ? 'Found $detected on this computer — share one as it is'
          : 'Point Grid at an engine you already run here',
      action: ChoiceRowAction.open,
      expanded: _open,
      onPressed: () => setState(() => _open = !_open),
      child: _open
          ? _RowBody(child: ExternalServers(network: widget.network))
          : null,
    );
  }
}

/// The inset a revealed form sits in, so every row opens to the same margins —
/// aligned with the row's text rather than its icon gutter, since what opens
/// belongs to what was read, not to the glyph beside it.
class _RowBody extends StatelessWidget {
  const _RowBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(47, 0, 15, 15), child: child);
}
