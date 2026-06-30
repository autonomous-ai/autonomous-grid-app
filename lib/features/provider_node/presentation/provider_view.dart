import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/backend_detector.dart';
import '../logic/provider_run_controller.dart';
import 'provider_running_card.dart';

/// Provider lifecycle. Enables the provider role when missing, then serves a
/// model — from a local GGUF (the main flow) or an external OpenAI-compatible
/// endpoint (`--at`) — and monitors the running provider. Downloading and
/// managing local models lives inline in the local engine block.
class ProviderView extends ConsumerStatefulWidget {
  const ProviderView({super.key});

  @override
  ConsumerState<ProviderView> createState() => _ProviderViewState();
}

class _ProviderViewState extends ConsumerState<ProviderView> {
  @override
  Widget build(BuildContext context) {
    final network = ref.watch(selectedNetworkProvider);

    // Reflect an engine that's still serving this grid (e.g. one that outlived
    // an app restart). Runs after the frame so it never mutates state mid-build;
    // the controller dedupes per grid.
    if (network != null) {
      final notifier = ref.read(providerRunControllerProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.reconcile(network.networkId);
      });
    }

    return SectionScaffold(
      title: 'Engines',
      child: ListView(children: const [_ServeSection()]),
    );
  }
}

/// Gates on network/provider/run-state, then offers the local-model serve (the
/// main flow) with the BYO external `--at` form as a secondary option.
class _ServeSection extends ConsumerWidget {
  const _ServeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final network = ref.watch(selectedNetworkProvider);
    final run = ref.watch(providerRunControllerProvider);

    if (network == null) {
      return const Text('Select a grid first from the Grids tab.');
    }
    if (!network.isProvider) {
      // Admins arriving from the grid's "Start engine" land here first. Frame
      // turning on engines as the opening step of the same guided path, not a
      // cold gate. Non-admins just get the "ask the owner" note from the card.
      if (network.role != NetworkRole.admin) {
        return EnableProviderCard(network: network);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ServeIntro(),
          const SizedBox(height: 16),
          EnableProviderCard(network: network),
        ],
      );
    }
    // One engine at a time: if one is already serving another grid, say so and
    // let the user stop it here first — don't show a Start form that would
    // silently leave the running engine to start a new one.
    if (run is ProviderRunActive && run.grid != network.networkId) {
      return _EngineBusyElsewhere(runningGridId: run.grid);
    }
    if (run is ProviderRunActive && run.grid == network.networkId) {
      return ProviderRunningCard(
          starting: run.starting, log: run.log, logHeight: 420);
    }

    final failedNote = run is ProviderRunFailed
        ? Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("Couldn't start last time: ${run.message}",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          )
        : null;

    // Windows can't host the built-in (llama.cpp) engine yet — don't show the
    // node-setup/serve path there; it would only dead-end. Offer BYO instead.
    if (Platform.isWindows) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failedNote != null) failedNote,
          const _BuiltInUnavailableNote(),
          const SizedBox(height: 16),
          _ExternalServers(network: network),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failedNote != null) failedNote,
        const _ServeIntro(),
        _EngineBlock(
          icon: Icons.dns_outlined,
          title: 'LLama.cpp',
          subtitle: 'Download a model, then start the built-in engine',
          child: ServeLocalCard(network: network),
        ),
        const SizedBox(height: 16),
        _ExternalServers(network: network),
        const SizedBox(height: 16),
        const NodeSetupCard(),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// A one-line "here's the path" intro above the engine blocks, so a first-time
/// user knows the three things happen in order.
class _ServeIntro extends StatelessWidget {
  const _ServeIntro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          "Share this computer's AI with your grid in three steps: "
          '1) set it up, 2) download a model, 3) start serving.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Shown on Windows in place of the built-in engine path, which isn't supported
/// there yet — so the user understands why and where to go instead.
class _BuiltInUnavailableNote extends StatelessWidget {
  const _BuiltInUnavailableNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Built-in engine not available on Windows yet',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    "Running a model directly on this Windows computer isn't "
                    'supported yet. You can still connect your own AI server below, '
                    'or use models other people share on the grid from the Playground.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when an engine is already serving a *different* grid. Only one engine
/// runs at a time, so rather than a Start form that would silently stop it, this
/// names the busy grid and offers a single Stop so the user is in control.
class _EngineBusyElsewhere extends ConsumerWidget {
  const _EngineBusyElsewhere({required this.runningGridId});

  final String runningGridId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final runningName =
        ref.watch(sessionProvider).byName(runningGridId)?.name ?? 'another grid';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.dns, color: Colors.green, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('An engine is already running on $runningName',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'You can run an engine on only one grid at a time. Stop '
                        'it to start one on this grid.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () =>
                    ref.read(providerRunControllerProvider.notifier).stop(),
                icon: const Icon(Icons.stop),
                label: Text('Stop engine on $runningName'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "bring your own server" section. Each external framework detected on this
/// machine (Ollama, LM Studio, …) gets its own card, pre-filled and ready to
/// start in one tap; a blank "Connect your own server" card follows for a server
/// running on another machine.
class _ExternalServers extends ConsumerWidget {
  const _ExternalServers({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backendsAsync = ref.watch(backendsProvider);
    final detected =
        backendsAsync.asData?.value.where((b) => b.isExternal).toList() ??
            const <DetectedBackend>[];
    // No data yet means we're still probing the machine — show that we're
    // looking so the empty list doesn't read as "nothing here".
    final isScanning = backendsAsync.isLoading && !backendsAsync.hasValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isScanning) const _ScanningForServersNote(),
        for (final backend in detected) ...[
          _ExternalServerBlock(
            // Keyed by kind so each framework keeps its own form state across
            // rescans (and the user's edits aren't swapped between cards).
            key: ValueKey(backend.kind),
            network: network,
            icon: Icons.dns_outlined,
            title: backend.label,
            subtitle: _backendSubtitle(backend),
            initialEndpoint: backend.baseUrl,
            initialModel: backend.models.isEmpty ? '' : backend.models.first,
            initialAdvertise: backend.models.isEmpty
                ? backend.label
                : deriveAdvertiseName(backend.models.first),
            suggestedModels: backend.models,
          ),
          const SizedBox(height: 16),
        ],
        _ExternalServerBlock(
          key: const ValueKey('manual'),
          network: network,
          icon: Icons.lan_outlined,
          title: 'Connect your own server',
          subtitle: detected.isEmpty
              ? 'Optional — only if you already run your own AI server (OpenAI-compatible)'
              : 'Or point at an AI server running on another computer (OpenAI-compatible)',
        ),
      ],
    );
  }
}

/// e.g. `localhost:11434/v1 · 3 models`.
String _backendSubtitle(DetectedBackend backend) {
  final host = backend.baseUrl.replaceFirst(RegExp(r'^https?://'), '');
  final count = backend.models.length;
  final models =
      count == 0 ? 'no models reported' : '$count model${count == 1 ? '' : 's'}';
  return '$host · $models';
}

/// A quiet "still looking" line shown while we probe this computer for running
/// AI engines (Ollama, LM Studio, …), so the not-yet-populated list doesn't read
/// as "nothing found" in the first second or two.
class _ScanningForServersNote extends StatelessWidget {
  const _ScanningForServersNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Looking for AI engines on this computer…',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A titled engine block — a card with an icon + title header so the serve paths
/// (built-in llama.cpp, each detected framework, your own server) are easy to
/// tell apart.
class _EngineBlock extends StatelessWidget {
  const _EngineBlock({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// One "Connect your own server" card — a self-contained external endpoint form
/// (`grid join --at`). Detected frameworks (Ollama, LM Studio, …) pass their
/// address/model in as initial values so it's pre-filled; the manual card starts
/// blank for a server running elsewhere.
class _ExternalServerBlock extends ConsumerStatefulWidget {
  const _ExternalServerBlock({
    super.key,
    required this.network,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.initialEndpoint = '',
    this.initialModel = '',
    this.initialAdvertise = '',
    this.suggestedModels = const [],
  });

  final NetworkCredential network;
  final IconData icon;
  final String title;
  final String subtitle;
  final String initialEndpoint;
  final String initialModel;
  final String initialAdvertise;

  /// Models the framework reported; non-empty turns the Model field into a
  /// dropdown (pick one of many) instead of a free-text box.
  final List<String> suggestedModels;

  @override
  ConsumerState<_ExternalServerBlock> createState() =>
      _ExternalServerBlockState();
}

class _ExternalServerBlockState extends ConsumerState<_ExternalServerBlock> {
  late final _endpoint = TextEditingController(text: widget.initialEndpoint);
  late final _model = TextEditingController(text: widget.initialModel);
  late final _advertise = TextEditingController(text: widget.initialAdvertise);

  @override
  void dispose() {
    _endpoint.dispose();
    _model.dispose();
    _advertise.dispose();
    super.dispose();
  }

  void _start() {
    ref.read(providerRunControllerProvider.notifier).startExternal(
          network: widget.network.networkId,
          endpoint: _endpoint.text.trim(),
          model: _model.text.trim(),
          advertiseAs: _advertise.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    return _EngineBlock(
      icon: widget.icon,
      title: widget.title,
      subtitle: widget.subtitle,
      child: _ServerForm(
        endpoint: _endpoint,
        model: _model,
        advertise: _advertise,
        suggestedModels: widget.suggestedModels,
        onStart: _start,
      ),
    );
  }
}

/// The external server form body: Server address, Model and Advertise-as fields
/// over a Start button. The controllers stay the source of truth so [onStart]
/// reads them; [suggestedModels] picks the Model field shape.
class _ServerForm extends StatelessWidget {
  const _ServerForm({
    required this.endpoint,
    required this.model,
    required this.advertise,
    required this.suggestedModels,
    required this.onStart,
  });

  final TextEditingController endpoint;
  final TextEditingController model;
  final TextEditingController advertise;
  final List<String> suggestedModels;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'http://192.168.1.10:8080/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        _ModelField(model: model, suggestedModels: suggestedModels),
        const SizedBox(height: 12),
        AdvertiseAsField(
          controller: advertise,
          hintText: 'qwen3-7b',
          optional: true,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: Listenable.merge([endpoint, model]),
            builder: (context, _) {
              final canStart = endpoint.text.trim().isNotEmpty &&
                  model.text.trim().isNotEmpty;
              return FilledButton.icon(
                onPressed: canStart ? onStart : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start engine'),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Model is a dropdown when the framework reports models (pick one of many), and
/// a free-text field otherwise (manual base URL → type the name). The [model]
/// controller stays the source of truth either way.
class _ModelField extends StatelessWidget {
  const _ModelField({required this.model, required this.suggestedModels});

  final TextEditingController model;
  final List<String> suggestedModels;

  @override
  Widget build(BuildContext context) {
    if (suggestedModels.isEmpty) {
      return TextField(
        controller: model,
        decoration: const InputDecoration(
          labelText: 'Model',
          hintText: 'gemma4-31b',
          border: OutlineInputBorder(),
        ),
      );
    }
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final value = suggestedModels.contains(model.text) ? model.text : null;
        return DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final m in suggestedModels)
              DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (v) {
            if (v != null) model.text = v;
          },
        );
      },
    );
  }
}
