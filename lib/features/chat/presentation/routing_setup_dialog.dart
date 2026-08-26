import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../playground/logic/playground_request.dart' show PlaygroundModality;
import '../logic/grid_model_catalog.dart';
import '../logic/routing_group.dart';
import 'orchestration_node_diagram.dart';

/// Opens the Fixed-mode setup dialog for [mode], returning the confirmed
/// [RoutingGroup] or null on cancel.
///
/// Shown once per group — the first time Fixed is picked for a chat that
/// doesn't have one saved yet (design spec §7.1).
Future<RoutingGroup?> showRoutingSetupDialog(
  BuildContext context, {
  required RoutingMode mode,
  RoutingGroup? initial,
}) => showDialog<RoutingGroup>(
  context: context,
  builder: (_) => RoutingSetupDialog(mode: mode, initial: initial),
);

/// The dialog's width, applied to both the title and the content — an
/// [AlertDialog] sizes itself to the wider of the two, so leaving either
/// unconstrained hands the width to whichever string is longest.
const double _dialogWidth = 940;

/// The models pinned as Fixed Brute Force proposers. Floor is two distinct
/// models — one proposer writes the draft, the other the grid picks to answer —
/// the ceiling is unbounded (it follows however many models the grid serves;
/// the backend no longer caps it).
const int _kMinModels = 2;

/// Distinct-model floors for the Dynamic/Feedback pools: Brute Force keeps at
/// least two distinct models available; Feedback Loop needs at least two
/// (a worker and a fully different judge).
const int _kMinBrutePool = 2;
const int _kMinJudgePool = 2;

/// Lowest the actual fan-out (steps) may go. The pool has to hold at least
/// two models, and both need to run — the pool floor and the steps floor meet.
const int _kMinBruteProposers = 2;

/// The modal shown the first time a chat picks routing: starts from whatever
/// the grid currently serves (all of it for Brute Force, the first two
/// distinct models for Feedback Loop's worker/judge), previews it live as a
/// node diagram, and lets the user edit it before confirming.
class RoutingSetupDialog extends ConsumerStatefulWidget {
  const RoutingSetupDialog({super.key, required this.mode, this.initial});

  final RoutingMode mode;

  /// An existing group to re-edit (the same mode is already pinned) — the
  /// dialog starts from what it spawned instead of a fresh grid pick.
  final RoutingGroup? initial;

  @override
  ConsumerState<RoutingSetupDialog> createState() => _RoutingSetupDialogState();
}

class _RoutingSetupDialogState extends ConsumerState<RoutingSetupDialog> {
  /// The editable model list for Brute Force.
  List<String> _models = [];

  /// The editable worker/judge pick for Feedback Loop.
  String? _worker;
  String? _judge;

  /// Brute Force's optional aggregator pin — null (the default) leaves it to
  /// the grid's own live, quality-ranked pick. See [RoutingGroup.aggregator].
  String? _aggregator;

  /// Fixed is the only reason this dialog is ever opened (design spec §7.1),
  /// so it starts selected — flipping to Dynamic is still one tap away.
  bool _fixed = true;

  /// Judge Loop, both Fixed and Dynamic: the max worker/judge rounds.
  /// Null = no cap (the relay uses its own MAX_ROUNDS); the field defaults to
  /// 5 so the wire carries an explicit bound unless the user clears it.
  int? _maxRounds = 5;

  /// Brute Force Dynamic: the candidate models the grid may draw its
  /// proposers from. Defaults to the whole served grid.
  List<String> _pool = [];

  /// Brute Force Dynamic: the proposer cap. Null = the grid decides (all free).
  int? _maxProposers;

  @override
  void initState() {
    super.initState();
    final served = _textModelIds(ref.read(gridModelCatalogProvider));
    // Re-editing a group this chat already pinned? Start from what it picked,
    // so "change the setup" opens onto the current models rather than a fresh
    // grid guess (the same chat picking the same mode again is a re-edit, not
    // a first setup).
    final existing = widget.initial;
    if (existing != null) {
      _fixed = existing.isFixed;
      switch (widget.mode) {
        case RoutingMode.bruteForce:
          if (existing.isFixed) {
            _models = [...?existing.models];
            _aggregator = existing.aggregator;
          } else {
            _pool = [...?existing.pool];
            if (_pool.length < _kMinBrutePool) _pool = [...served];
            _maxProposers = existing.maxProposers ?? 3;
          }
        case RoutingMode.judgeLoop:
          _worker = existing.worker;
          _judge = existing.judge;
          _maxRounds = existing.maxRounds ?? _maxRounds;
          // Pinned uses worker + judge; Dynamic uses a pool of candidates.
          _pool = [...?existing.pool];
          if (_pool.length < _kMinJudgePool) _pool = [...served];
      }
      return;
    }
    // Otherwise start from what the grid serves right now, not an AI-guessed
    // pick — no request to wait on, so the dialog has something to show and
    // edit the instant it opens.
    switch (widget.mode) {
      case RoutingMode.bruteForce:
        // Leave the last served model out of the proposer list so the
        // aggregator always has a distinct candidate — the UI keeps the two
        // sets disjoint even though the backend would accept an overlap.
        _models = served.take(served.length - 1).toList();
        if (served.isNotEmpty) _aggregator = served.last;
        // Dynamic starts with the whole grid as the pool (no restriction) and
        // a filled proposer count of three — a concrete number, not a hint.
        _pool = [...served];
        _maxProposers = 3;
      case RoutingMode.judgeLoop:
        _worker = served.isNotEmpty ? served[0] : null;
        _judge = served.length > 1 ? served[1] : null;
        _pool = [...served];
    }
  }

  /// Adds [id] if it isn't picked, drops it if it is — the multi-select
  /// menu's one gesture for both directions. Bounded by [_kMinModels] (the
  /// floor) and the number of served models (the ceiling) at the call site,
  /// so this never needs to check either bound itself.
  void _toggleModel(String id) => setState(() {
    if (!_models.remove(id)) _models.add(id);
    // A removed proposer can still be the pinned aggregator (the two lists
    // aren't required to overlap — the backend validates it against the
    // whole grid, not just the pinned proposers), so nothing to reconcile
    // here.
  });

  void _setAggregator(String? id) => setState(() => _aggregator = id);

  void _setFixed(bool value) => setState(() => _fixed = value);

  void _setWorker(String id) => setState(() => _worker = id);

  void _setJudge(String id) => setState(() => _judge = id);

  void _setMaxRounds(int? v) => setState(() => _maxRounds = v);

  void _togglePool(String id) => setState(() {
    if (!_pool.remove(id)) {
      _pool.add(id);
    } else if (_maxProposers != null && _maxProposers! > _pool.length) {
      // Shrinking the pool can't leave the proposer cap above the number of
      // distinct models still in it — steps must equal available models.
      _maxProposers = _pool.length;
    }
  });

  void _selectAllPool() {
    final served = _textModelIds(ref.read(gridModelCatalogProvider));
    setState(() => _pool = [...served]);
  }

  void _setMaxProposers(int? v) => setState(() => _maxProposers = v);

  bool get _canConfirm {
    if (widget.mode == RoutingMode.judgeLoop) {
      return _fixed
          ? (_worker != null && _judge != null)
          : _pool.length >= _kMinJudgePool;
    }
    if (!_fixed) return _pool.length >= _kMinBrutePool; // Brute Force Dynamic
    return _models.length >= _kMinModels; // Brute Force Fixed
  }

  /// The pool to send: null when it's the whole grid (or empty) — the relay
  /// then lets the grid pick from everything it serves. A narrowed pool is
  /// sent as-is.
  List<String>? _poolOut() {
    if (_pool.isEmpty) return null;
    final served = _textModelIds(ref.read(gridModelCatalogProvider));
    if (served.isNotEmpty && _pool.length == served.length) return null;
    return List.of(_pool);
  }

  RoutingGroup _buildGroup() {
    if (!_fixed) {
      if (widget.mode == RoutingMode.bruteForce) {
        final served = _textModelIds(ref.read(gridModelCatalogProvider));
        final isFullPool = _pool.isNotEmpty && _pool.length == served.length;
        // No pool restriction AND no proposer cap = plain Dynamic: return a
        // config-less group so the wire is the bare auto/brute_force id rather
        // than a redundant full-grid pool pin. Any narrower pool or a cap pins
        // the dynamic config.
        if (isFullPool && _maxProposers == null) {
          return RoutingGroup(mode: widget.mode, isFixed: false);
        }
        return RoutingGroup(
          mode: widget.mode,
          isFixed: false,
          pool: _pool.isEmpty ? served : _pool,
          maxProposers: _maxProposers,
        );
      }
      return RoutingGroup(
        mode: widget.mode,
        isFixed: false,
        pool: _poolOut(),
        maxRounds: _maxRounds,
      );
    }
    return switch (widget.mode) {
      RoutingMode.bruteForce => RoutingGroup(
        mode: widget.mode,
        isFixed: true,
        models: _models,
        aggregator: _aggregator,
      ),
      RoutingMode.judgeLoop => RoutingGroup(
        mode: widget.mode,
        isFixed: true,
        worker: _worker,
        judge: _judge,
        maxRounds: _maxRounds,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);

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
              widget.mode == RoutingMode.bruteForce
                  ? 'Several AI models answer your question at the same time, then the answers are combined into one best reply.'
                  : 'One AI writes a first answer, a second AI checks it for mistakes, and they keep improving it until it is good enough.',
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
                fixed: _fixed,
                models: _models,
                worker: _worker,
                judge: _judge,
                aggregator: _aggregator,
                dynamicProposers: _fixed ? null : _maxProposers,
              ),
              const SizedBox(height: 18),
              _PinnedDynamicSection(fixed: _fixed, onChanged: _setFixed),
              const SizedBox(height: 18),
              if (widget.mode == RoutingMode.bruteForce)
                _fixed
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _ProposerMultiSelect(
                              models: _models,
                              onToggle: _toggleModel,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _AggregatorSelect(
                              aggregator: _aggregator,
                              onChanged: _setAggregator,
                              excluding: _models,
                            ),
                          ),
                        ],
                      )
                    : _DynamicBruteForceSection(
                        pool: _pool,
                        maxProposers: _maxProposers,
                        onTogglePool: _togglePool,
                        onMaxProposersChanged: _setMaxProposers,
                      )
              else
                _fixed
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _WorkerJudgeRows(
                            worker: _worker,
                            judge: _judge,
                            onWorkerChanged: _setWorker,
                            onJudgeChanged: _setJudge,
                          ),
                          const SizedBox(height: 12),
                          _MaxRoundsField(
                            value: _maxRounds,
                            onChanged: _setMaxRounds,
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _PoolMultiSelect(
                              pool: _pool,
                              minCount: _kMinJudgePool,
                              helper:
                                  'The models that write and check the answer.',
                              onToggle: _togglePool,
                              onSelectAll: _selectAllPool,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MaxRoundsField(
                              value: _maxRounds,
                              onChanged: _setMaxRounds,
                            ),
                          ),
                        ],
                      ),
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

/// The live preview: the current pick, drawn as a queued diagram — for
/// Pinned, the real models chosen; for Dynamic (and for Pinned before enough
/// are chosen), generic role names standing in for whichever ones the grid
/// ends up running. Always drawn, in both modes: the *shape* of a mode is
/// worth seeing before committing to it, even with nothing pinned yet.
class _DiagramPreview extends StatelessWidget {
  const _DiagramPreview({
    required this.mode,
    required this.fixed,
    required this.models,
    required this.worker,
    required this.judge,
    required this.aggregator,
    this.dynamicProposers,
  });

  final RoutingMode mode;
  final bool fixed;
  final List<String> models;
  final String? worker;
  final String? judge;

  /// Brute Force Dynamic: draws this many generic proposer nodes live off the
  /// "Max proposers" input, so the diagram follows the number the user types.
  final int? dynamicProposers;

  /// The pinned aggregator, or null when the grid decides live — see
  /// [RoutingGroup.aggregator].
  final String? aggregator;

  static const _you = DiagramNode('You', NodeStatus.queued);
  static const _answer = DiagramNode('Answer', NodeStatus.queued);
  static const _genericProposers = [
    DiagramNode('AI answers', NodeStatus.queued),
    DiagramNode('AI answers', NodeStatus.queued),
  ];
  static const _genericWorker = DiagramNode('First writer', NodeStatus.queued);
  static const _genericJudge = DiagramNode('Checker', NodeStatus.queued);

  // The grid's live pick when nothing is pinned — see [RoutingGroup.aggregator].
  static const _genericAggregator = DiagramNode(
    'Final reply',
    NodeStatus.queued,
  );

  /// Padding on all four sides of the card, doubled for the height reserved
  /// below so the card never visibly resizes as the model count changes.
  static const double _cardPadding = 12;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);

    final dynCount = dynamicProposers ?? 0;
    final proposerNodes = fixed && models.length >= 2
        ? [for (final id in models) DiagramNode(id, NodeStatus.queued)]
        : (dynCount >= 1
              ? List<DiagramNode>.generate(
                  dynCount,
                  (_) => const DiagramNode('AI answers', NodeStatus.queued),
                )
              : _genericProposers);
    final diagram = switch (mode) {
      RoutingMode.bruteForce => OrchestrationNodeDiagram.bruteForce(
        you: _you,
        proposers: proposerNodes,
        aggregator: fixed && aggregator != null
            ? DiagramNode(aggregator!, NodeStatus.queued)
            : _genericAggregator,
        answer: _answer,
        showStatus: false,
      ),
      RoutingMode.judgeLoop => OrchestrationNodeDiagram.judgeLoop(
        you: _you,
        worker: fixed && worker != null
            ? DiagramNode(worker!, NodeStatus.queued)
            : _genericWorker,
        judge: fixed && judge != null
            ? DiagramNode(judge!, NodeStatus.queued)
            : _genericJudge,
        answer: _answer,
        showStatus: false,
      ),
    };

    // Resize with what's actually drawn — the count of proposer nodes the
    // diagram shows (the pinned list, or the generic two when dynamic or too
    // few). The diagram is FittedBox'd (scaleDown) inside, so a taller shape
    // just scales down; reserving more than is drawn only inflates the card.
    final proposersShown = proposerNodes.length;
    final cardHeight =
        (mode == RoutingMode.bruteForce
            ? bruteForceDiagramHeight(proposersShown)
            : judgeLoopDiagramHeight) +
        _cardPadding * 2;

    return Container(
      width: double.infinity,
      height: cardHeight,
      padding: const EdgeInsets.all(_cardPadding),
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(AppControl.radius),
      ),
      // The diagram's node/connector geometry is fixed pixels and can run
      // wider than the dialog (a 4-model Brute Force fan-out is ~660px
      // against this dialog's ~430px content width) — shrink to fit rather
      // than force a horizontal scroll just to see the shape at a glance.
      child: FittedBox(fit: BoxFit.scaleDown, child: diagram),
    );
  }
}

/// Brute Force's proposer pick — a multi-select built on the app's own
/// [labeledFieldDecoration]/[appMenuStyle] field construction (the same one
/// [AppSelectField] itself uses), so it reads as the same kind of control
/// even though [AppSelectField] is single-value only and can't be reused
/// outright for a toggle-many pick. One line: the closed field names the
/// first model and a "+N more" count rather than wrapping every pick onto
/// its own row, and opening it lists everything this grid serves with a
/// check beside each one already picked — tapping a row toggles it in or out
/// without closing the menu.
class _ProposerMultiSelect extends ConsumerStatefulWidget {
  const _ProposerMultiSelect({required this.models, required this.onToggle});

  final List<String> models;
  final ValueChanged<String> onToggle;

  @override
  ConsumerState<_ProposerMultiSelect> createState() =>
      _ProposerMultiSelectState();
}

class _ProposerMultiSelectState extends ConsumerState<_ProposerMultiSelect> {
  final _menu = MenuController();

  String get _summary {
    if (widget.models.isEmpty) return 'Choose models…';
    if (widget.models.length == 1) return widget.models.single;
    return '${widget.models.first} +${widget.models.length - 1} more';
  }

  @override
  Widget build(BuildContext context) {
    // menuChildren render in a detached overlay, not this widget's own
    // subtree — a parent's rebuild doesn't reach them, so this has to watch
    // theme itself (see the same note on approval_picker.dart's menu rows).
    AppTheme.watch(context);
    final candidates = _textModelIds(ref.watch(gridModelCatalogProvider));
    final n = widget.models.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Models that answer'),
        MenuAnchor(
          controller: _menu,
          alignmentOffset: const Offset(0, 6),
          style: appMenuStyle(),
          menuChildren: candidates.isEmpty
              ? [
                  MenuItemButton(
                    onPressed: null,
                    child: Text(
                      "This grid isn't serving any models yet.",
                      style: TextStyle(color: AppPalette.textFaint),
                    ),
                  ),
                ]
              : [
                  for (final id in candidates)
                    _CheckableModelItem(
                      id: id,
                      checked: widget.models.contains(id),
                      onPressed: widget.models.contains(id)
                          ? (n > _kMinModels ? () => widget.onToggle(id) : null)
                          : (n < candidates.length - 1
                                ? () => widget.onToggle(id)
                                : null),
                    ),
                ],
          builder: (context, controller, _) => InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            borderRadius: BorderRadius.circular(12),
            child: InputDecorator(
              isEmpty: false,
              decoration: labeledFieldDecoration('', fill: AppCard.inset),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.models.isEmpty
                          ? kFieldTextStyle.copyWith(
                              color: AppPalette.textFaint,
                            )
                          : kFieldTextStyle.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 24,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Brute Force's optional aggregator pin — an ordinary single-value
/// [AppSelectField], since exactly one aggregator (or none, meaning the grid
/// decides) is the whole choice. [excluding] drops whatever is already picked
/// as a proposer, so the two lists never overlap in the UI (the relay itself
/// would accept it, but a model that both fans out and synthesizes reads wrong).
class _AggregatorSelect extends ConsumerWidget {
  const _AggregatorSelect({
    required this.aggregator,
    required this.onChanged,
    required this.excluding,
  });

  final String? aggregator;
  final ValueChanged<String?> onChanged;
  final List<String> excluding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The aggregator stays disjoint from the proposer list. `excluding` (the
    // pinned proposers) trims the served models down to what's left to pick.
    final candidates = [
      for (final id in _textModelIds(ref.watch(gridModelCatalogProvider)))
        if (!excluding.contains(id)) id,
    ];
    return AppSelectField<String>(
      label: 'Writes the final reply',
      value: aggregator,
      options: [
        for (final id in candidates) AppSelectOption(value: id, label: id),
      ],
      onChanged: onChanged,
    );
  }
}

/// One row in the multi-select's menu — drawn exactly like
/// [AppSelectField]'s own option row (same padding, hover wash, tick slot)
/// so the two dropdowns read as the same control, not two different ones —
/// the only real difference is that a tap here toggles instead of closing
/// the menu, and more than one row can carry the tick at once.
class _CheckableModelItem extends StatelessWidget {
  const _CheckableModelItem({
    required this.id,
    required this.checked,
    required this.onPressed,
  });

  final String id;
  final bool checked;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    final radius = BorderRadius.circular(AppControl.radius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: checked ? AppSurface.accentWash : Colors.transparent,
              borderRadius: radius,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppControl.fontSize,
                      height: 1.2,
                      fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                      color: onPressed == null
                          ? AppPalette.textFaint
                          : AppPalette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                SizedBox(
                  width: 16,
                  child: checked
                      ? Icon(
                          Icons.check_rounded,
                          size: AppControl.iconSize,
                          color: AppPalette.accentMuted,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Feedback Loop's editable pick — one [AppSelectField] per role, each
/// offering every model the grid serves except whichever the other role
/// already holds (worker and judge can't be the same model).
/// Brute Force's Dynamic-mode edit: a proposer cap + the candidate pool. The
/// grid still picks within the pool by its own ranking (stays Dynamic), up to
/// the cap the user names here — instead of fanning out to everything free.
class _DynamicBruteForceSection extends ConsumerStatefulWidget {
  const _DynamicBruteForceSection({
    required this.pool,
    required this.maxProposers,
    required this.onTogglePool,
    required this.onMaxProposersChanged,
  });

  final List<String> pool;
  final int? maxProposers;
  final ValueChanged<String> onTogglePool;
  final ValueChanged<int?> onMaxProposersChanged;

  @override
  ConsumerState<_DynamicBruteForceSection> createState() =>
      _DynamicBruteForceSectionState();
}

class _DynamicBruteForceSectionState
    extends ConsumerState<_DynamicBruteForceSection> {
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _NumberField(
            label: 'Models at once',
            // Always a concrete filled number — never a blank "All" hint. The
            // pool holds at least 3 distinct models, but only 2 need to run.
            value: widget.maxProposers ?? _kMinBruteProposers,
            min: _kMinBruteProposers,
            max: widget.pool.length >= _kMinBruteProposers
                ? widget.pool.length
                : _kMinBruteProposers,
            helper: 'How many models answer at the same time.',
            onChanged: widget.onMaxProposersChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _PoolMultiSelect(
            pool: widget.pool,
            minCount: _kMinBrutePool,
            helper: 'The models the grid may choose from.',
            onToggle: widget.onTogglePool,
            onSelectAll: () {
              final served = _textModelIds(ref.read(gridModelCatalogProvider));
              for (final id in served) {
                if (!widget.pool.contains(id)) widget.onTogglePool(id);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// Feedback Loop's round cap — shown in BOTH Fixed and Dynamic, since the
/// user asked for a per-chat round bound regardless of whether worker/judge
/// are pinned. The worker keeps revising against the judge's failed checks,
/// bounded at this many rounds; the judge then returns whichever round scored
/// best. Bounded 1–10 to match the relay's `_MAX_UI_ROUNDS`.
class _MaxRoundsField extends StatelessWidget {
  const _MaxRoundsField({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return _NumberField(
      label: 'Max improvements',
      value: value,
      min: 1,
      max: 10,
      hint: '5',
      helper: 'The maximum number of times the answer is checked and improved.',
      onChanged: onChanged,
    );
  }
}

/// A compact bounded integer input, used for both Dynamic Brute Force's
/// proposer cap and Feedback Loop's round cap. A cleared field = null = "let
/// the grid decide" (the payload then omits the bound entirely). Out-of-range
/// entries clamp to [min]/[max].
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 1,
    required this.max,
    this.hint = 'Auto',
    this.helper,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final int min;
  final int max;
  final String hint;
  final String? helper;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value?.toString() ?? '',
  );

  void _onChange(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      widget.onChanged(null);
      return;
    }
    final n = int.tryParse(trimmed);
    if (n == null) return; // partial/illegal digits while typing
    final clamped = n.clamp(widget.min, widget.max);
    if (n != clamped) {
      final text = clamped.toString();
      _c.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    widget.onChanged(clamped);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(widget.label),
        TextField(
          controller: _c,
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          onChanged: _onChange,
          decoration: labeledFieldDecoration(
            '',
            fill: AppCard.inset,
          ).copyWith(hintText: widget.hint),
          style: kFieldTextStyle,
        ),
        if (widget.helper != null) ...[
          const SizedBox(height: 3),
          Text(
            widget.helper!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Brute Force Dynamic's candidate pool — a multi-select over everything this
/// grid serves, same control as [_ProposerMultiSelect] but without the
/// leave-one-for-the-aggregator reserve (Dynamic's aggregator is picked live,
/// not from this list), and with a floor of one model instead of two.
class _PoolMultiSelect extends ConsumerStatefulWidget {
  const _PoolMultiSelect({
    required this.pool,
    required this.minCount,
    required this.onToggle,
    required this.onSelectAll,
    this.helper,
  });

  final List<String> pool;

  final String? helper;

  /// The fewest distinct models the pool must keep — Brute Force 3, Feedback 2.
  final int minCount;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;

  @override
  ConsumerState<_PoolMultiSelect> createState() => _PoolMultiSelectState();
}

class _PoolMultiSelectState extends ConsumerState<_PoolMultiSelect> {
  final _menu = MenuController();

  String get _summary {
    final p = widget.pool;
    if (p.isEmpty) return 'All models';
    if (p.length == 1) return p.single;
    return '${p.first} +${p.length - 1} more';
  }

  @override
  Widget build(BuildContext context) {
    // menuChildren render in a detached overlay — see _ProposerMultiSelect.
    AppTheme.watch(context);
    final candidates = _textModelIds(ref.watch(gridModelCatalogProvider));
    final n = widget.pool.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Available models'),
        MenuAnchor(
          controller: _menu,
          alignmentOffset: const Offset(0, 6),
          style: appMenuStyle(),
          menuChildren: candidates.isEmpty
              ? [
                  MenuItemButton(
                    onPressed: null,
                    child: Text(
                      "This grid isn't serving any models yet.",
                      style: TextStyle(color: AppPalette.textFaint),
                    ),
                  ),
                ]
              : [
                  _PoolAllRow(
                    allSelected: n > 0 && n == candidates.length,
                    onTap: n > 0 && n == candidates.length
                        ? null
                        : widget.onSelectAll,
                  ),
                  for (final id in candidates)
                    _CheckableModelItem(
                      id: id,
                      checked: widget.pool.contains(id),
                      onPressed: widget.pool.contains(id)
                          ? (n > widget.minCount
                                ? () => widget.onToggle(id)
                                : null)
                          : (n < candidates.length
                                ? () => widget.onToggle(id)
                                : null),
                    ),
                ],
          builder: (context, controller, _) => InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            borderRadius: BorderRadius.circular(12),
            child: InputDecorator(
              isEmpty: false,
              decoration: labeledFieldDecoration('', fill: AppCard.inset),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.pool.isEmpty
                          ? kFieldTextStyle.copyWith(
                              color: AppPalette.textFaint,
                            )
                          : kFieldTextStyle.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 24,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.helper != null) ...[
          const SizedBox(height: 3),
          Text(
            widget.helper!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// The top row of the Pool menu: "All models". Tapping selects every model the
/// grid serves — the one-gesture way back to the unfiltered default after the
/// user has been trimming the pool. Disabled once everything is picked.
class _PoolAllRow extends StatelessWidget {
  const _PoolAllRow({required this.allSelected, required this.onTap});

  final bool allSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: allSelected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: radius,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'All models',
                    style: TextStyle(
                      fontSize: AppControl.fontSize,
                      height: 1.2,
                      fontWeight: FontWeight.w400,
                      color: onTap == null
                          ? AppPalette.textFaint
                          : AppPalette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                SizedBox(
                  width: 16,
                  child: allSelected
                      ? Icon(
                          Icons.check_rounded,
                          size: AppControl.iconSize,
                          color: AppPalette.accentMuted,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Feedback Loop's Pinned-mode pick — one [AppSelectField] per role, each
/// offering every model the grid serves except whichever the other role
/// already holds (worker and judge can't be the same model).
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AppSelectField<String?>(
            label: 'First writer',
            value: worker,
            options: [
              for (final id in candidates)
                if (id != judge) AppSelectOption(value: id, label: id),
            ],
            onChanged: (id) {
              if (id != null) onWorkerChanged(id);
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppSelectField<String?>(
            label: 'Checker',
            value: judge,
            options: [
              for (final id in candidates)
                if (id != worker) AppSelectOption(value: id, label: id),
            ],
            onChanged: (id) {
              if (id != null) onJudgeChanged(id);
            },
          ),
        ),
      ],
    );
  }
}

/// The Pinned/Dynamic segmented control — always defaults to Pinned, since
/// that's the only reason this dialog opens, but a flip to Dynamic is one tap
/// and closes with no model list pinned at all.
class _PinnedDynamicSection extends StatelessWidget {
  const _PinnedDynamicSection({required this.fixed, required this.onChanged});

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
            SegmentSpec(label: 'Same models'),
            SegmentSpec(label: 'Grid picks'),
          ],
          selected: fixed ? 0 : 1,
          onChanged: (i) => onChanged(i == 0),
        ),
        const SizedBox(height: 6),
        Text(
          routingHoldNote(isFixed: fixed),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The grid's served text models — media modes can't chat, so they're not
/// candidates for a routing pick, and neither is the router family itself
/// ("Auto" / "Brute Force" / "Feedback Loop" — see [isRouterFamilyId]): a
/// Brute Force group cannot pin "Brute Force" as one of its own proposers.
List<String> _textModelIds(List<GridModelGroup> catalog) => [
  for (final group in catalog)
    for (final option in group.options)
      if (option.modality == PlaygroundModality.text &&
          !isRouterFamilyId(option.id))
        option.id,
];
