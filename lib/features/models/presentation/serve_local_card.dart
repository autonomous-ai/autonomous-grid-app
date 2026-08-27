import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/auto_serve_store.dart';
import '../../../infrastructure/state/models/local_files.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/copy/plural.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/log_view.dart';
import '../../../shared/widgets/node_name_field.dart';
import '../../node_setup/logic/background_model_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/advertise_name.dart';
import '../../../core/context_length.dart';
import '../logic/engine_setup_controller.dart';
import '../logic/engine_status.dart';
import '../logic/model_download_status.dart';
import '../logic/model_group.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_storage.dart';
import '../logic/models_providers.dart';
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

  /// What this computer joins under. Pre-filled with its own name in
  /// [initState], so the field shows what a start would actually use rather than
  /// a blank box the user has to guess at.
  final _nodeName = TextEditingController();
  String? _model;
  String? _advertiseFilledFor;

  /// The user's chosen context length in tokens. Null means "use the model's
  /// maximum" — resolved from [modelMaxContextProvider] at start time. Reset on
  /// every model change so the slider defaults to the new model's own maximum.
  int? _ctxSize;

  @override
  void initState() {
    super.initState();
    _nodeName.text = ref.read(nodeNameProvider);
    // The summary quotes both fields, so it has to follow them while they are
    // being edited — a preview that only caught up on Done would be wrong at
    // exactly the moment someone is checking it.
    _advertise.addListener(_onDetailEdited);
    _nodeName.addListener(_onDetailEdited);
  }

  void _onDetailEdited() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _advertise.removeListener(_onDetailEdited);
    _nodeName.removeListener(_onDetailEdited);
    _advertise.dispose();
    _nodeName.dispose();
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

  /// The pills beside a model in the picker: what it costs on disk, and — for
  /// a split set — whether every part of it is actually here.
  ///
  /// The part count used to read "1 parts" for a download that had landed one
  /// shard of three: wrong as grammar, and wrong as a fact, since it offered an
  /// unloadable model as if it were ready to serve.
  List<AppSelectBadge> _modelBadges(ModelGroup group) {
    // Hoisted so the badges can be pluralised: `isComplete` and `isSplit` each
    // already imply a count is known, but neither promotes the nullable field.
    final expected = group.expectedParts;
    return [
      AppSelectBadge(modelSizeLabel(group.sizeBytes)),
      if (group.isComplete && group.isSplit && expected != null)
        AppSelectBadge('$expected ${plural(expected, 'part')}')
      else if (!group.isComplete && expected != null)
        AppSelectBadge(
          'Unfinished · ${group.partCount} of $expected '
          '${plural(expected, 'part')}',
          tone: AppBadgeTone.warning,
        ),
    ];
  }

  /// Whether the pre-filled details are open for editing. Shut by default: the
  /// summary above already says what they are, so opening is for changing them,
  /// not for reading them.
  bool _editingDetails = false;

  /// Keeps a start-on-open record in step with the form. No-ops unless one is
  /// armed *for this model*.
  ///
  /// **TODO(BE): nothing arms one any more.** The tick that wrote these records
  /// was removed on 2026-08-26, so `refresh` only ever finds a record made
  /// before that date. `AutoServeStarter` still reads them, which is why this
  /// and [_armedGroup] stay: an old install can still be set to serve on open,
  /// and it must keep opening on the model it is armed with. New installs have
  /// no way to turn it on at all. Give it a new home or retire the feature.
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
  /// The window this model will actually start on — the typed value, or the
  /// default read from the model's own ceiling. Null only while that ceiling is
  /// still being read, where the summary simply leaves the clause out rather
  /// than guessing a number the engine might not use.
  int? _effectiveContext(String model) {
    if (_ctxSize case final chosen?) return chosen;
    final max = ref.watch(modelMaxContextProvider(model)).asData?.value;
    return max == null ? null : defaultContextLength(max);
  }

  String _advertiseName(String model) {
    final typed = _advertise.text.trim();
    return typed.isEmpty ? deriveAdvertiseName(model) : typed;
  }

  void _start(String model) {
    ref.read(analyticsProvider).engineSetupSubmitted('built_in', model: model);
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
          // Blank falls back to this computer's own name, inside the controller
          // — so an emptied field behaves the same as one never touched.
          nodeName: _nodeName.text,
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
      'A model download stopped partway. '
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
      'Downloading a model. This can take a few minutes.',
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
    const SizedBox(height: 10),
    // Every one of these is pre-filled correctly from the model itself, so most
    // starts never touch any of them. Folding them away was right and not
    // enough: hidden, they were also *unverifiable* — you could not find out
    // what name the grid would see without opening a section. A sentence says
    // it in a line and still opens.
    _DetailsSummary(
      advertiseAs: _advertiseName(selected.primary.name),
      nodeName: _nodeName.text.trim(),
      contextTokens: _effectiveContext(selected.primary.name),
      open: _editingDetails,
      onToggle: () => setState(() => _editingDetails = !_editingDetails),
    ),
    if (_editingDetails) ...[
      const SizedBox(height: 10),
      _DetailsPanel(
        names: [
          AdvertiseAsField(controller: _advertise, hintText: 'Qwen3.6-35B-A3B'),
          const SizedBox(height: 14),
          NodeNameField(controller: _nodeName),
        ],
        window: ContextLengthField(
          model: selected.primary.name,
          value: _ctxSize,
          // The panel and the summary both carry the number already — see
          // [ContextWindowField.inline].
          inline: true,
          onChanged: (tokens) {
            setState(() => _ctxSize = tokens);
            // A machine still carrying a start-on-open record has to open with
            // the window shown here, not the one from when it was armed.
            _refreshAutoServe(selected.primary.name);
          },
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
    // An incomplete group always knows how many shards it wants — `isComplete`
    // is true whenever it doesn't — but the field stays nullable to the reader.
    final expected = selected.expectedParts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!selected.isComplete && expected != null) ...[
          Text(
            "This model didn't finish downloading. ${selected.partCount} of "
            '$expected ${plural(expected, 'part')} '
            '${expected == 1 ? 'is' : 'are'} here. It needs all of them '
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
                label: const Text('Start sharing'),
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

/// The three pre-filled details, as one sentence you can read or open.
///
/// This replaced a "Names and context window" expander, and the difference is
/// not that it is shorter. A disclosure hides a *decision*; these are not
/// decisions, they are defaults derived from the model and the machine, and the
/// question a person actually has about a default is "what is it?" — which a
/// closed expander is the one shape that cannot answer. Read it in a line,
/// press Change only if it is wrong.
///
/// It also puts the weight back where it belongs. The model picker is the one
/// real choice in this form; three full-width fields under it were drawn at
/// exactly the same size, so nothing on the card looked more important than
/// anything else.
class _DetailsSummary extends StatelessWidget {
  const _DetailsSummary({
    required this.advertiseAs,
    required this.nodeName,
    required this.contextTokens,
    required this.open,
    required this.onToggle,
  });

  final String advertiseAs;
  final String nodeName;

  /// Null while the model's ceiling is still being read.
  final int? contextTokens;

  final bool open;
  final VoidCallback onToggle;

  /// Written as the grid will see it, not as the fields are labelled. "Model
  /// name shown to the grid" is the right label above an input and the wrong
  /// words in a sentence, where what matters is the name itself.
  String get _sentence {
    final from = nodeName.isEmpty ? 'this computer' : nodeName;
    final window = contextTokens == null
        ? ''
        : ', remembering ${formatContextLength(contextTokens!)}';
    return 'Shared as “$advertiseAs” from “$from”$window.';
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            _sentence,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        // A text button, not a chevron: the row is a sentence, and a disclosure
        // arrow on a sentence promises more words rather than the fields that
        // actually open.
        TextButton(
          onPressed: onToggle,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(open ? 'Done' : 'Change'),
        ),
      ],
    );
  }
}

/// The opened details, as one plate rather than a run of loose fields.
///
/// Open, the three settings used to flow at the same level as the model picker
/// and the Start button, so a form with **one** decision in it looked like a
/// form with six. Nothing said the fields belonged to the sentence that revealed
/// them, or to each other.
///
/// A plate says both at once, and its two surfaces are picked by measurement
/// rather than by taste.
///
/// **Lifted, not recessed.** [AdvertiseAsField] and [NodeNameField] both fill
/// themselves [AppCard.inset]; a recessed plate would be that same `#F7F7F5`
/// and the fields would vanish into it. White keeps them readable as insets.
///
/// **Rimmed with [AppGlass.lift], not [AppCard.hair].** In light this plate is
/// `#FFFFFF` on a block that is *also* `#FFFFFF` ([AppGlass.surfaceFill]) — 1:1,
/// so fill does no work at all here and the edge is the whole separation (§2).
/// `hair` is 6% black and disappears on a white pane, which is the case `lift`
/// exists for. The shadow carries the rest.
///
/// A rule splits the two questions inside it, because what the grid calls this
/// and how much it remembers are not the same kind of setting.
class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.names, required this.window});

  /// The two "what the grid sees" fields.
  final List<Widget> names;

  /// The context-window control, which answers a different question.
  final Widget window;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppGlass.lift),
        boxShadow: AppGlass.cardShadow,
      ),
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...names,
          const SizedBox(height: 16),
          Divider(height: 1, thickness: 1, color: AppPalette.divider),
          const SizedBox(height: 15),
          window,
        ],
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
      'Downloading the built-in engine. This takes a moment.',
    EngineSetupDone() =>
      'The built-in engine is ready. Download a model to run it.',
    _ =>
      "The built-in engine isn't set up on this computer yet. Grid downloads "
          'it for you, then you can run a model here.',
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
