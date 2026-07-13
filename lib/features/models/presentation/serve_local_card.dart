import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/log_view.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/advertise_name.dart';
import '../logic/context_length.dart';
import '../logic/engine_setup_controller.dart';
import '../logic/engine_status.dart';
import '../logic/model_group.dart';
import '../logic/model_pull_controller.dart';
import '../logic/models_providers.dart';
import 'context_length_field.dart';
import 'model_manager_dialog.dart';

/// A model download in flight — from the node-setup auto-download (its
/// "Download a model" step) or a manual pull in the model manager — reduced to
/// what the engine block needs. Outer null means nothing is downloading; a null
/// [pct] means "downloading, percent not known yet".
({int? pct})? _modelDownloadStatus(ModelPullState pull, NodeSetupState setup) {
  if (pull is ModelPulling) return (pct: _pctOf(pull.progress));
  if (setup is NodeSetupRunning && setup.current.isDownload) {
    return (pct: _pctOf(setup.progress));
  }
  return null;
}

int? _pctOf(DownloadProgress? p) =>
    (p != null && !p.isIndeterminate) ? p.pct!.round() : null;

/// The built-in llama.cpp engine block: serve a locally pulled GGUF model via
/// `grid join <grid> --serve <gguf> --advertise-as <name>`. Downloading and
/// managing models lives in the model manager, opened here from
/// "Download or manage models".
class ServeLocalCard extends ConsumerStatefulWidget {
  const ServeLocalCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ServeLocalCard> createState() => _ServeLocalCardState();
}

class _ServeLocalCardState extends ConsumerState<ServeLocalCard> {
  final _advertise = TextEditingController();
  String? _model;
  String? _advertiseFilledFor;

  /// The user's chosen context length in tokens. Null means "use the model's
  /// maximum" — resolved from [modelMaxContextProvider] at start time. Reset on
  /// every model change so the slider defaults to the new model's own maximum.
  int? _ctxSize;

  @override
  void dispose() {
    _advertise.dispose();
    super.dispose();
  }

  /// Pre-fill the advertise field from the model name, once per selection — but
  /// keep the user's manual edits while the same model stays selected.
  void _syncAdvertiseFor(String model) {
    if (model == _advertiseFilledFor) return;
    _advertiseFilledFor = model;
    final derived = deriveAdvertiseName(model);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _advertise.text = derived;
    });
  }

  void _start(String model) {
    final advertise = _advertise.text.trim();
    // Fall back to the model's default (200k, capped to its max) when the user
    // hasn't moved the slider; if the max isn't read yet, leave --ctx-size off
    // so the engine uses its own default.
    final max = ref.read(modelMaxContextProvider(model)).asData?.value;
    final ctxSize =
        _ctxSize ?? (max != null ? defaultContextLength(max) : null);
    // --advertise-as is always sent; derive from the model name if left blank.
    ref.read(providerRunControllerProvider.notifier).startLocal(
          network: widget.network.networkId,
          model: model,
          advertiseAs:
              advertise.isEmpty ? deriveAdvertiseName(model) : advertise,
          ctxSize: ctxSize,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = ref.watch(modelGroupsProvider);
    final llamaInstalled = ref.watch(engineStatusProvider).llamaInstalled;
    final download = _modelDownloadStatus(
      ref.watch(modelPullControllerProvider),
      ref.watch(nodeSetupControllerProvider),
    );

    // Default to the first model; keep selection valid if the list changes. A
    // model is keyed by the file we serve (a split set's first shard).
    ModelGroup? selected;
    for (final group in groups) {
      if (group.primary.name == _model) {
        selected = group;
        break;
      }
    }
    selected ??= groups.isEmpty ? null : groups.first;
    if (selected != null) _syncAdvertiseFor(selected.primary.name);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _engineSection(context, theme,
          llamaInstalled: llamaInstalled,
          download: download,
          groups: groups,
          selected: selected),
    );
  }

  /// The block's contents, in priority order:
  /// 1. a model download in flight → progress (the live bar + Cancel are below);
  /// 2. the engine isn't installed → set it up first. Serving is impossible
  ///    without the engine even when a model is on disk, so a leftover GGUF from
  ///    a removed engine must NOT present a dead "Start local engine" — gate
  ///    on the engine, not on whether a model happens to exist;
  /// 3. engine installed but no model → prompt to download one;
  /// 4. engine installed + a model ready → the serve controls.
  List<Widget> _engineSection(
    BuildContext context,
    ThemeData theme, {
    required bool llamaInstalled,
    required ({int? pct})? download,
    required List<ModelGroup> groups,
    required ModelGroup? selected,
  }) {
    if (download != null) return _downloadingSection(theme, download.pct);
    if (!llamaInstalled) return const [_EngineSetupSection()];
    if (selected == null) return _downloadPromptSection(context, theme);
    return _serveControls(groups, selected);
  }

  /// A model is downloading (node setup or a manual pull): show progress in
  /// place of the download button, since the live bar + Cancel are below.
  List<Widget> _downloadingSection(ThemeData theme, int? pct) => [
        Text(
          'Downloading a model — this can take a few minutes.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            // Not tappable — it reflects the download already running below.
            onPressed: null,
            icon: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: Text(pct != null ? 'Downloading… $pct%' : 'Downloading…'),
          ),
        ),
      ];

  List<Widget> _downloadPromptSection(BuildContext context, ThemeData theme) => [
        Text(
          'No models on this computer yet. Download one to start serving.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => showModelManager(context),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Download a model'),
          ),
        ),
      ];

  List<Widget> _serveControls(List<ModelGroup> groups, ModelGroup selected) => [
        DropdownButtonFormField<String>(
          initialValue: selected.primary.name,
          decoration: const InputDecoration(
            labelText: 'Local model',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final group in groups)
              DropdownMenuItem(
                value: group.primary.name,
                child: Text(group.isSplit
                    ? '${group.displayName} · ${group.partCount} parts'
                    : group.displayName),
              ),
          ],
          // Reset the context choice so the slider falls back to the new
          // model's own maximum instead of carrying over the previous one.
          onChanged: (value) => setState(() {
            _model = value;
            _ctxSize = null;
          }),
        ),
        const SizedBox(height: 12),
        AdvertiseAsField(
          controller: _advertise,
          hintText: 'Qwen3.6-35B-A3B',
        ),
        const SizedBox(height: 12),
        ContextLengthField(
          model: selected.primary.name,
          value: _ctxSize,
          onChanged: (tokens) => setState(() => _ctxSize = tokens),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _start(selected.primary.name),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start local engine'),
              ),
              TextButton.icon(
                onPressed: () => showModelManager(context),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Download or manage models'),
              ),
            ],
          ),
        ),
      ];
}

/// Shown in the built-in engine block when the engine isn't set up on this
/// computer (fresh machine, or the user removed it). Installs it in place — one
/// download, no package manager and no password — with a live log, so the block
/// is self-sufficient and never points at the node-setup card (which hides
/// itself once another engine already covers text inference).
class _EngineSetupSection extends ConsumerWidget {
  const _EngineSetupSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(engineSetupControllerProvider);

    final log = switch (state) {
      EngineSetupRunning(:final log) => log,
      EngineSetupFailed(:final log) => log,
      _ => const <String>[],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _intro(state),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        ..._errorLine(theme, state),
        const SizedBox(height: 14),
        _EngineSetupActions(state: state),
        if (log.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(height: 160, child: LogView(lines: log)),
        ],
      ],
    );
  }

  /// The lead-in sentence for the current state.
  static String _intro(EngineSetupState state) => switch (state) {
    EngineSetupRunning() =>
      'Downloading the built-in engine — this takes a moment.',
    EngineSetupDone() =>
      'The built-in engine is ready. Download a model to run it.',
    _ =>
      "The built-in engine isn't set up on this computer yet. Grid downloads "
          'it for you — then you can run a model here.',
  };

  /// The error line under the intro, if the install failed.
  static List<Widget> _errorLine(ThemeData theme, EngineSetupState state) {
    if (state is! EngineSetupFailed) return const [];
    return [
      const SizedBox(height: 10),
      Text(
        state.message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    ];
  }
}

/// The action button for the setup section: start, retry, or a disabled spinner
/// while the engine downloads.
class _EngineSetupActions extends ConsumerWidget {
  const _EngineSetupActions({required this.state});

  final EngineSetupState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(engineSetupControllerProvider.notifier);
    if (state is EngineSetupRunning) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('Setting up…'),
        ),
      );
    }

    final isFailed = state is EngineSetupFailed;
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: notifier.run,
        icon: Icon(isFailed ? Icons.refresh : Icons.download_outlined, size: 18),
        label: Text(isFailed ? 'Try again' : 'Set up built-in engine'),
      ),
    );
  }
}
