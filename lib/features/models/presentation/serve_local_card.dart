import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/auto_serve_store.dart';
import '../../../infrastructure/state/models/local_files.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/log_view.dart';
import '../../node_setup/logic/background_model_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/advertise_name.dart';
import '../logic/context_length.dart';
import '../logic/engine_setup_controller.dart';
import '../logic/engine_status.dart';
import '../logic/model_download_status.dart';
import '../logic/model_group.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_storage.dart';
import '../logic/models_providers.dart';
import 'auto_serve_row.dart';
import 'context_length_field.dart';
import 'model_manager_dialog.dart';

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

  /// The model set to start when the app opens, if it's still on disk. The
  /// block opens on it: it is the one this computer will actually serve, so
  /// landing on an unrelated first-in-the-list would show a tick that looks off
  /// while start-on-open is very much on.
  ModelGroup? _armedGroup(List<ModelGroup> groups) {
    final prefs = ref.read(autoServePrefsProvider);
    if (!prefs.enabled || prefs.networkId != widget.network.networkId) {
      return null;
    }
    return groups
        .where((group) => group.primary.name == prefs.model)
        .firstOrNull;
  }

  /// Whether *this* model is the one set to start when the app opens. Read from
  /// the record, not from a bare on/off: the tick sits beside one model in a
  /// picker, so it has to mean that model.
  bool _autoServes(ModelGroup group) {
    final prefs = ref.watch(autoServePrefsProvider);
    return prefs.enabled &&
        prefs.networkId == widget.network.networkId &&
        prefs.model == group.primary.name;
  }

  /// The *other* model set to start on open, if there is one. Said out loud
  /// beside an unticked box, because "off" next to this model would otherwise
  /// read as "nothing starts on its own" while something does.
  String? _armedElsewhere(ModelGroup group) {
    final prefs = ref.watch(autoServePrefsProvider);
    if (!prefs.enabled || _autoServes(group)) return null;
    final model = prefs.model;
    if (model == null || model.isEmpty) return null;
    return ref
        .read(modelGroupsProvider)
        .where((other) => other.primary.name == model)
        .map((other) => other.displayName)
        .firstOrNull;
  }

  /// The pills beside a model in the picker: what it costs on disk, and — for
  /// a split set — whether every part of it is actually here.
  ///
  /// The part count used to read "1 parts" for a download that had landed one
  /// shard of three: wrong as grammar, and wrong as a fact, since it offered an
  /// unloadable model as if it were ready to serve.
  List<AppSelectBadge> _modelBadges(ModelGroup group) => [
    AppSelectBadge(modelSizeLabel(group.sizeBytes)),
    if (group.isComplete && group.isSplit)
      AppSelectBadge('${group.expectedParts} parts')
    else if (!group.isComplete)
      AppSelectBadge(
        'Unfinished · ${group.partCount} of ${group.expectedParts} parts',
        tone: AppBadgeTone.warning,
      ),
  ];

  /// Keeps the start-on-open record in step with the form. No-ops unless the
  /// box is ticked *for this model*.
  void _refreshAutoServe(String model) {
    ref
        .read(autoServePrefsProvider.notifier)
        .refresh(
          networkId: widget.network.networkId,
          model: model,
          advertiseAs: _advertiseName(model),
          ctxSize: _ctxSize,
        );
  }

  /// The name to announce [model] under: what the user typed, or the one
  /// derived from the filename when they left the field alone.
  String _advertiseName(String model) {
    final typed = _advertise.text.trim();
    return typed.isEmpty ? deriveAdvertiseName(model) : typed;
  }

  void _start(String model) {
    _refreshAutoServe(model);
    final advertise = _advertise.text.trim();
    // Fall back to the model's default (200k, capped to its max) when the user
    // hasn't moved the slider; if the max isn't read yet, leave --ctx-size off
    // so the engine uses its own default.
    final max = ref.read(modelMaxContextProvider(model)).asData?.value;
    final ctxSize =
        _ctxSize ?? (max != null ? defaultContextLength(max) : null);
    // --advertise-as is always sent; derive from the model name if left blank.
    ref
        .read(providerRunControllerProvider.notifier)
        .startLocal(
          network: widget.network.networkId,
          model: model,
          advertiseAs: advertise.isEmpty
              ? deriveAdvertiseName(model)
              : advertise,
          ctxSize: ctxSize,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = ref.watch(modelGroupsProvider);
    final llamaInstalled = ref.watch(engineStatusProvider).llamaInstalled;
    final download = liveModelDownload(
      pull: ref.watch(modelPullControllerProvider),
      setup: ref.watch(nodeSetupControllerProvider),
      background: ref.watch(backgroundModelControllerProvider),
    );
    // A `.gguf.part` on disk with no live stream: a download that was
    // interrupted and can pick up where it left off.
    final partial = download == null
        ? ref.watch(downloadingModelsProvider).firstOrNull
        : null;

    // Default to the first model; keep selection valid if the list changes. A
    // model is keyed by the file we serve (a split set's first shard).
    ModelGroup? selected;
    for (final group in groups) {
      if (group.primary.name == _model) {
        selected = group;
        break;
      }
    }
    selected ??= _armedGroup(groups) ?? (groups.isEmpty ? null : groups.first);
    if (selected != null) _syncAdvertiseFor(selected.primary.name);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _engineSection(
        context,
        theme,
        llamaInstalled: llamaInstalled,
        download: download,
        partial: partial,
        groups: groups,
        selected: selected,
      ),
    );
  }

  /// The block's contents, in priority order:
  /// 1. a model download in flight → progress (the live bar + Cancel are below);
  /// 2. the engine isn't installed → set it up first. Serving is impossible
  ///    without the engine even when a model is on disk, so a leftover GGUF from
  ///    a removed engine must NOT present a dead "Start local engine" — gate
  ///    on the engine, not on whether a model happens to exist;
  /// 3. a download stalled partway (a `.gguf.part` on disk) → offer to resume it,
  ///    rather than pretend the computer is empty;
  /// 4. engine installed but no model → prompt to download one;
  /// 5. engine installed + a model ready → the serve controls.
  List<Widget> _engineSection(
    BuildContext context,
    ThemeData theme, {
    required bool llamaInstalled,
    required ({int? pct})? download,
    required DownloadingModel? partial,
    required List<ModelGroup> groups,
    required ModelGroup? selected,
  }) {
    if (download != null) return _downloadingSection(theme, download.pct);
    if (!llamaInstalled) return const [_EngineSetupSection()];
    if (selected == null && partial != null) {
      return _resumeSection(context, theme, partial);
    }
    if (selected == null) return _downloadPromptSection(context, theme);
    return _serveControls(groups, selected);
  }

  /// A download stopped partway — the app quit, or the transfer dropped — leaving
  /// a `.gguf.part` on disk. Say so honestly (how much landed, no fake percent)
  /// and point at the manager, where downloading the same model resumes from
  /// where it left off instead of starting over.
  List<Widget> _resumeSection(
    BuildContext context,
    ThemeData theme,
    DownloadingModel partial,
  ) => [
    Text(
      'A model download stopped partway — '
      '${partial.gbSoFar.toStringAsFixed(1)} GB is already here. '
      'Download it again to finish; it carries on from where it left off.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: () => showModelManager(context),
        icon: const Icon(Icons.download_outlined, size: 18),
        label: const Text('Finish downloading'),
      ),
    ),
  ];

  /// A model is downloading (node setup or a manual pull): show progress in
  /// place of the download button, since the live bar + Cancel are below.
  List<Widget> _downloadingSection(ThemeData theme, int? pct) => [
    Text(
      'Downloading a model — this can take a few minutes.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        // Not tappable — it reflects the download already running below.
        onPressed: null,
        icon: const AppSpinner.onAccent(),
        label: Text(pct != null ? 'Downloading… $pct%' : 'Downloading…'),
      ),
    ),
  ];

  List<Widget> _downloadPromptSection(BuildContext context, ThemeData theme) =>
      [
        Text(
          'No models on this computer yet. Download one to start serving.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
    // AppSelectField, not DropdownButtonFormField: Material's popup can't be
    // made to match the app's floating menus (square, edge-to-edge, no inset).
    AppSelectField<String>(
      label: 'Local model',
      value: selected.primary.name,
      options: [
        for (final group in groups)
          AppSelectOption(
            value: group.primary.name,
            label: group.displayName,
            badges: _modelBadges(group),
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
    // The display name and the context window are both pre-filled correctly from
    // the model itself, so most starts never touch them. Folding them away keeps
    // the block to one decision — which model — while leaving both a tap away.
    _AdvancedOptions(
      children: [
        AdvertiseAsField(controller: _advertise, hintText: 'Qwen3.6-35B-A3B'),
        const SizedBox(height: 12),
        ContextLengthField(
          model: selected.primary.name,
          value: _ctxSize,
          onChanged: (tokens) {
            setState(() => _ctxSize = tokens);
            // A start-on-open model has to open with the window shown here,
            // not the one that was in the field when the box was ticked.
            _refreshAutoServe(selected.primary.name);
          },
        ),
      ],
    ),
    // Only offered for a model that can actually start. Ticking it against an
    // unfinished download would arm a launch that fails where nobody is
    // looking.
    if (selected.isComplete) ...[
      const SizedBox(height: 12),
      AutoServeRow(
        value: _autoServes(selected),
        armedElsewhere: _armedElsewhere(selected),
        modelLabel: selected.displayName,
        onChanged: (enabled) => ref
            .read(autoServePrefsProvider.notifier)
            .set(
              enabled: enabled,
              networkId: widget.network.networkId,
              model: selected.primary.name,
              advertiseAs: _advertiseName(selected.primary.name),
              ctxSize: _ctxSize,
            ),
      ),
    ],
    const SizedBox(height: 16),
    _ServeActions(
      selected: selected,
      onStart: () => _start(selected.primary.name),
      onManage: () => showModelManager(context),
    ),
  ];
}

/// What the block offers for the selected model: start it, or — when it never
/// finished downloading — say so and offer the one thing that helps.
///
/// A split model missing a part cannot load (llama.cpp opens the first shard
/// and reads its siblings from the same folder), so starting it would fail
/// seconds later in the CLI's own words. The count is said in parts, the unit
/// the download itself is counted in.
class _ServeActions extends StatelessWidget {
  const _ServeActions({
    required this.selected,
    required this.onStart,
    required this.onManage,
  });

  final ModelGroup selected;
  final VoidCallback onStart;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!selected.isComplete) ...[
          Text(
            "This model didn't finish downloading — ${selected.partCount} of "
            '${selected.expectedParts} parts are here. It needs all of them '
            'before it can run.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppPalette.warn),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (selected.isComplete)
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start local engine'),
              )
            else
              FilledButton.icon(
                onPressed: onManage,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Finish downloading'),
              ),
            TextButton.icon(
              onPressed: onManage,
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Download or manage models'),
            ),
          ],
        ),
      ],
    );
  }
}

/// A quiet disclosure holding the settings that are already right by default —
/// the grid-facing name (derived from the model) and the context window (the
/// model's own maximum, capped). Both matter when you want them and are noise
/// when you don't, so the block leads with the single real choice, the model,
/// and keeps these one tap away.
///
/// Not the same as [ContextLengthField]'s own collapsed tile, which stays nested
/// inside this: that one carries a slider that would otherwise dominate the card
/// even when expanded here.
class _AdvancedOptions extends StatelessWidget {
  const _AdvancedOptions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // Drop ExpansionTile's divider lines so it reads as part of the form
      // rather than a separate section.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4),
        minTileHeight: 40,
        dense: true,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: Text(
          'Name and context window',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: children,
      ),
    );
  }
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
          icon: const AppSpinner.onAccent(),
          label: const Text('Setting up…'),
        ),
      );
    }

    final isFailed = state is EngineSetupFailed;
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: notifier.run,
        icon: Icon(
          isFailed ? Icons.refresh : Icons.download_outlined,
          size: 18,
        ),
        label: Text(isFailed ? 'Try again' : 'Set up built-in engine'),
      ),
    );
  }
}
