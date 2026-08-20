import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/playground_request.dart' show PlaygroundModality;
import '../logic/grid_model_catalog.dart';
import '../logic/routing_group.dart';
import '../logic/routing_suggestion_controller.dart';
import 'orchestration_node_diagram.dart';

/// Opens the Fixed-mode setup dialog for [mode], returning the confirmed
/// [RoutingGroup] or null on cancel.
///
/// Shown once per group — the first time Fixed is picked for a chat that
/// doesn't have one saved yet (design spec §7.1). [conversation] is what the
/// suggestion probe summarizes; empty for a chat with nothing said yet.
Future<RoutingGroup?> showRoutingSetupDialog(
  BuildContext context, {
  required RoutingMode mode,
  List<ChatMessage> conversation = const [],
}) => showDialog<RoutingGroup>(
  context: context,
  builder: (_) => RoutingSetupDialog(mode: mode, conversation: conversation),
);

/// The dialog's width, applied to both the title and the content — an
/// [AlertDialog] sizes itself to the wider of the two, so leaving either
/// unconstrained hands the width to whichever string is longest.
const double _dialogWidth = 460;

/// The models a Brute Force group may pin. Floor matches what a fan-out needs
/// to mean anything; ceiling mirrors the backend's own `MAX_N`
/// (`effort_router.py`) — this UI has no way to read that constant live, so
/// it's hardcoded here to match it.
const int _kMinModels = 2;
const int _kMaxModels = 4;

/// The modal shown the first time a chat picks Fixed routing: fetches an
/// AI-generated suggestion of which models to use (via
/// [routingSuggestionControllerProvider]), previews it live as a node
/// diagram, and lets the user edit it before confirming.
class RoutingSetupDialog extends ConsumerStatefulWidget {
  const RoutingSetupDialog({
    super.key,
    required this.mode,
    this.conversation = const [],
  });

  final RoutingMode mode;
  final List<ChatMessage> conversation;

  @override
  ConsumerState<RoutingSetupDialog> createState() => _RoutingSetupDialogState();
}

class _RoutingSetupDialogState extends ConsumerState<RoutingSetupDialog> {
  /// The editable model list for Brute Force. Empty until the suggestion
  /// lands or the user starts adding models by hand.
  List<String> _models = [];

  /// The editable worker/judge pick for Feedback Loop.
  String? _worker;
  String? _judge;

  /// Fixed is the only reason this dialog is ever opened (design spec §7.1),
  /// so it starts selected — flipping to Dynamic is still one tap away.
  bool _fixed = true;

  /// Set the moment a suggestion is first copied into the editable state
  /// above, so a later rebuild (the user editing a row) never overwrites
  /// what they changed with the same suggestion again.
  bool _appliedSuggestion = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    ref
        .read(routingSuggestionControllerProvider.notifier)
        .fetchSuggestion(widget.mode, conversation: widget.conversation);
  }

  void _applySuggestion(RoutingGroup group) {
    if (_appliedSuggestion) return;
    _appliedSuggestion = true;
    setState(() {
      _models = [...?group.models];
      _worker = group.worker;
      _judge = group.judge;
    });
  }

  void _removeModel(String id) => setState(() => _models.remove(id));

  void _addModel(String id) => setState(() => _models.add(id));

  void _trimLastModel() => setState(() {
    if (_models.isNotEmpty) _models.removeLast();
  });

  void _setWorker(String id) => setState(() => _worker = id);

  void _setJudge(String id) => setState(() => _judge = id);

  void _setFixed(bool value) => setState(() => _fixed = value);

  bool get _canConfirm {
    if (!_fixed) return true;
    return switch (widget.mode) {
      RoutingMode.bruteForce => _models.length >= _kMinModels,
      RoutingMode.judgeLoop => _worker != null && _judge != null,
    };
  }

  RoutingGroup _buildGroup() {
    if (!_fixed) return RoutingGroup(mode: widget.mode, isFixed: false);
    return switch (widget.mode) {
      RoutingMode.bruteForce => RoutingGroup(
        mode: widget.mode,
        isFixed: true,
        models: _models,
      ),
      RoutingMode.judgeLoop => RoutingGroup(
        mode: widget.mode,
        isFixed: true,
        worker: _worker,
        judge: _judge,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final state = ref.watch(routingSuggestionControllerProvider);
    // React to the suggestion landing, rather than applying it inline during
    // build — a plain `if (state is Ready) _applySuggestion(...)` here would
    // be a side effect of building this widget, which repo convention §2
    // reserves for outside build() (this is that "outside": a listener
    // callback, not the build method itself).
    ref.listen(routingSuggestionControllerProvider, (_, next) {
      if (next is RoutingSuggestionReady) _applySuggestion(next.group);
    });

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(26, 22, 26, 0),
      contentPadding: const EdgeInsets.fromLTRB(26, 14, 26, 0),
      actionsPadding: const EdgeInsets.fromLTRB(26, 14, 22, 20),
      title: SizedBox(
        width: _dialogWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set up ${widget.mode.displayName}',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick which models answer in this chat, or leave it to the '
              'grid to choose fresh every time.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              _DiagramPreview(
                mode: widget.mode,
                ready: state is RoutingSuggestionReady,
                fixed: _fixed,
                models: _models,
                worker: _worker,
                judge: _judge,
              ),
              const SizedBox(height: 18),
              _SuggestionSection(
                state: state,
                mode: widget.mode,
                models: _models,
                worker: _worker,
                judge: _judge,
                onRemoveModel: _removeModel,
                onWorkerChanged: _setWorker,
                onJudgeChanged: _setJudge,
                onRetry: _fetch,
              ),
              if (widget.mode == RoutingMode.bruteForce &&
                  state is RoutingSuggestionReady) ...[
                const SizedBox(height: 18),
                _ModelCountSection(
                  models: _models,
                  onTrim: _trimLastModel,
                  onAdd: _addModel,
                ),
              ],
              const SizedBox(height: 18),
              _FixedDynamicSection(fixed: _fixed, onChanged: _setFixed),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canConfirm
              ? () => Navigator.of(context).pop(_buildGroup())
              : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

/// The live preview: the current editable pick, drawn as a queued diagram.
/// Nothing to show while the suggestion hasn't landed (the section below
/// already carries the loading/failed state), and nothing to show for
/// Dynamic — it has no fixed model list to preview.
class _DiagramPreview extends StatelessWidget {
  const _DiagramPreview({
    required this.mode,
    required this.ready,
    required this.fixed,
    required this.models,
    required this.worker,
    required this.judge,
  });

  final RoutingMode mode;
  final bool ready;
  final bool fixed;
  final List<String> models;
  final String? worker;
  final String? judge;

  static const _you = DiagramNode('You', NodeStatus.queued);
  static const _answer = DiagramNode('Answer', NodeStatus.queued);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (!fixed || !ready) return const SizedBox.shrink();

    final diagram = switch (mode) {
      // The suggestion pins the whole proposer set but names no separate
      // aggregator (RoutingGroup.models is a flat list) — the last model in
      // the current pick stands in for it here. It's a real one of the
      // models the user chose, never an invented name; which one actually
      // aggregates a given turn is still the grid's call.
      RoutingMode.bruteForce when models.length >= 2 =>
        OrchestrationNodeDiagram.bruteForce(
          you: _you,
          proposers: [
            for (final id in models.sublist(0, models.length - 1))
              DiagramNode(id, NodeStatus.queued),
          ],
          aggregator: DiagramNode(models.last, NodeStatus.queued),
          answer: _answer,
        ),
      RoutingMode.judgeLoop when worker != null && judge != null =>
        OrchestrationNodeDiagram.judgeLoop(
          you: _you,
          worker: DiagramNode(worker!, NodeStatus.queued),
          judge: DiagramNode(judge!, NodeStatus.queued),
          answer: _answer,
        ),
      _ => null,
    };
    if (diagram == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(AppControl.radius),
      ),
      child: diagram,
    );
  }
}

/// "Suggested by the grid" — the probe's state, and the editable pick once
/// it lands.
class _SuggestionSection extends StatelessWidget {
  const _SuggestionSection({
    required this.state,
    required this.mode,
    required this.models,
    required this.worker,
    required this.judge,
    required this.onRemoveModel,
    required this.onWorkerChanged,
    required this.onJudgeChanged,
    required this.onRetry,
  });

  final RoutingSuggestionState state;
  final RoutingMode mode;
  final List<String> models;
  final String? worker;
  final String? judge;
  final ValueChanged<String> onRemoveModel;
  final ValueChanged<String> onWorkerChanged;
  final ValueChanged<String> onJudgeChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Suggested by the grid',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: AppFont.medium,
          ),
        ),
        const SizedBox(height: 8),
        switch (state) {
          RoutingSuggestionLoading() => const _LoadingRow(),
          RoutingSuggestionFailed(:final reason) => _FailedRow(
            reason: reason,
            onRetry: onRetry,
          ),
          RoutingSuggestionReady() =>
            mode == RoutingMode.bruteForce
                ? _ModelRows(models: models, onRemove: onRemoveModel)
                : _WorkerJudgeRows(
                    worker: worker,
                    judge: judge,
                    onWorkerChanged: onWorkerChanged,
                    onJudgeChanged: onJudgeChanged,
                  ),
        },
      ],
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        const AppSpinner(size: SpinnerSize.small),
        const SizedBox(width: 10),
        Text(
          'Asking the grid…',
          style: TextStyle(color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}

class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 16, color: AppPalette.warn),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reason, style: TextStyle(color: AppPalette.textSecondary)),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One removable row per suggested model — Brute Force's editable pick.
class _ModelRows extends StatelessWidget {
  const _ModelRows({required this.models, required this.onRemove});

  final List<String> models;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (models.isEmpty) {
      return Text(
        "The grid didn't suggest any models.",
        style: TextStyle(color: AppPalette.textSecondary),
      );
    }
    return Column(
      children: [
        for (final id in models) ...[
          _ModelRow(
            id: id,
            onRemove: models.length > _kMinModels ? () => onRemove(id) : null,
          ),
          if (id != models.last) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.id, required this.onRemove});

  final String id;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(AppControl.radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFont.codeStyle(color: AppPalette.textPrimary),
            ),
          ),
          AppIconButton(
            icon: Icons.close_rounded,
            tooltip: onRemove == null
                ? 'Keep at least $_kMinModels models'
                : 'Remove this model',
            onPressed: onRemove,
            destructive: true,
          ),
        ],
      ),
    );
  }
}

/// Feedback Loop's editable pick — a labeled row per role, each swappable for
/// another model the grid serves.
class _WorkerJudgeRows extends ConsumerWidget {
  const _WorkerJudgeRows({
    required this.worker,
    required this.judge,
    required this.onWorkerChanged,
    required this.onJudgeChanged,
  });

  final String? worker;
  final String? judge;
  final ValueChanged<String> onWorkerChanged;
  final ValueChanged<String> onJudgeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = _textModelIds(ref.watch(gridModelCatalogProvider));
    return Column(
      children: [
        _RoleRow(
          role: 'Worker',
          model: worker,
          candidates: [
            for (final id in candidates)
              if (id != judge) id,
          ],
          onPick: onWorkerChanged,
        ),
        const SizedBox(height: 6),
        _RoleRow(
          role: 'Judge',
          model: judge,
          candidates: [
            for (final id in candidates)
              if (id != worker) id,
          ],
          onPick: onJudgeChanged,
        ),
      ],
    );
  }
}

class _RoleRow extends StatelessWidget {
  const _RoleRow({
    required this.role,
    required this.model,
    required this.candidates,
    required this.onPick,
  });

  final String role;
  final String? model;
  final List<String> candidates;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(AppControl.radius),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              role,
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFont.medium,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              model ?? 'Not picked',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFont.codeStyle(color: AppPalette.textPrimary),
            ),
          ),
          _ModelMenuButton(
            icon: Icons.swap_horiz_rounded,
            tooltip: 'Swap this model',
            emptyLabel: 'No other models to swap in',
            candidates: candidates,
            onPick: onPick,
          ),
        ],
      ),
    );
  }
}

/// "How many models" — a stepper, Brute Force only. Growing the count needs a
/// model picked by hand (there's no way to guess a good one), so the "+" side
/// opens the same small model menu as a swap, and the "-" side trims the last
/// row — mirroring the per-row remove buttons above.
class _ModelCountSection extends ConsumerWidget {
  const _ModelCountSection({
    required this.models,
    required this.onTrim,
    required this.onAdd,
  });

  final List<String> models;
  final VoidCallback onTrim;
  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final n = models.length;
    final candidates = [
      for (final id in _textModelIds(ref.watch(gridModelCatalogProvider)))
        if (!models.contains(id)) id,
    ];

    return Row(
      children: [
        Text(
          'How many models',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: AppFont.medium,
          ),
        ),
        const Spacer(),
        AppIconButton(
          icon: Icons.remove_rounded,
          tooltip: 'Use one fewer model',
          onPressed: n > _kMinModels ? onTrim : null,
        ),
        SizedBox(
          width: 22,
          child: Text(
            '$n',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: AppFont.medium,
            ),
          ),
        ),
        n < _kMaxModels
            ? _ModelMenuButton(
                icon: Icons.add_rounded,
                tooltip: 'Add a model',
                emptyLabel: "This grid isn't serving another model to add",
                candidates: candidates,
                onPick: onAdd,
              )
            : AppIconButton(
                icon: Icons.add_rounded,
                tooltip: 'At most $_kMaxModels models',
                onPressed: null,
              ),
      ],
    );
  }
}

/// The Fixed/Dynamic segmented control — always defaults to Fixed, since
/// that's the only reason this dialog opens, but a flip to Dynamic is one tap
/// and closes with no model list pinned at all.
class _FixedDynamicSection extends StatelessWidget {
  const _FixedDynamicSection({required this.fixed, required this.onChanged});

  final bool fixed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSegmented(
          expand: true,
          segments: const [
            SegmentSpec(label: 'Fixed'),
            SegmentSpec(label: 'Dynamic'),
          ],
          selected: fixed ? 0 : 1,
          onChanged: (i) => onChanged(i == 0),
        ),
        const SizedBox(height: 6),
        Text(
          fixed ? 'Same models every message.' : 'Re-picked every message.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// A small icon button opening a menu of model ids — the swap/add affordance
/// shared by [_RoleRow] and [_ModelCountSection].
class _ModelMenuButton extends StatefulWidget {
  const _ModelMenuButton({
    required this.icon,
    required this.tooltip,
    required this.emptyLabel,
    required this.candidates,
    required this.onPick,
  });

  final IconData icon;
  final String tooltip;
  final String emptyLabel;
  final List<String> candidates;
  final ValueChanged<String> onPick;

  @override
  State<_ModelMenuButton> createState() => _ModelMenuButtonState();
}

class _ModelMenuButtonState extends State<_ModelMenuButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    // menuChildren render in a detached overlay, not this widget's own
    // subtree — a parent's rebuild doesn't reach them, so this has to watch
    // theme itself (see the same note on approval_picker.dart's menu rows).
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      menuChildren: widget.candidates.isEmpty
          ? [
              MenuItemButton(
                onPressed: null,
                child: Text(
                  widget.emptyLabel,
                  style: TextStyle(color: AppPalette.textFaint),
                ),
              ),
            ]
          : [
              for (final id in widget.candidates)
                MenuItemButton(
                  onPressed: () => widget.onPick(id),
                  child: Text(
                    id,
                    style: AppFont.codeStyle(
                      color: AppPalette.textPrimary,
                      scale: 0.95,
                    ),
                  ),
                ),
            ],
      builder: (context, controller, _) => AppIconButton(
        icon: widget.icon,
        tooltip: widget.tooltip,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The grid's served text models — media modes can't chat, so they're not
/// candidates for a routing pick.
List<String> _textModelIds(List<GridModelGroup> catalog) => [
  for (final group in catalog)
    for (final option in group.options)
      if (option.modality == PlaygroundModality.text) option.id,
];
