import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/model_usage.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredWindowLabel, formatCount;
import '../../theme/app_theme.dart';
import '../../widgets/skeleton.dart';
import 'pill_panel_shell.dart';

/// The models this grid can answer with, busiest first — the panel behind the
/// pill's model count.
///
/// **Shaped around a lopsided grid**, because that is the shape real ones have:
/// one model carries most of the work, and *which one, and by how much* is
/// exactly what a count of models cannot say. So the leader is lifted out of the
/// list into a block wide enough for the whole of what the relay measured —
/// fresh input, cached prefill, output, requests — and every other model stays
/// one compact line of the two figures worth comparing across a column.
///
/// Ids in mono, like every other place the app shows one: a model id gets pasted
/// into a config, so `l`/`1` and `0`/`O` have to stay apart. Every figure is sans
/// with tabular digits — they refresh in place under a pointer that is already
/// resting on them, and digits of differing width make the column twitch.
class GridModelsList extends ConsumerWidget {
  const GridModelsList({super.key});

  /// How tall the "others" list may grow before it scrolls. Shorter than the
  /// panels that are nothing but a list: the hero above it already spends its
  /// own height, and a popover taller than the window is worse than a scrollbar.
  static const double _restMaxHeight = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final models = ref.watch(gridModelsProvider);
    final loading = ref.watch(gridOverviewLoading);
    // Nothing has landed yet — not even *how many* models there are, which is
    // why the skeleton's heading is a bar too.
    if (models.isEmpty) {
      return loading
          ? const _ModelsSkeleton()
          : const PillPanelMessage(text: 'This grid serves no model yet.');
    }
    // Online only. A model whose one machine went offline stays in the catalog,
    // and counting an offline node as serving it would promise a route the grid
    // cannot take.
    final nodes = ref.watch(gridOnlineNodesProvider);
    // The grid-level rollup: the denominator every share here is drawn against,
    // and the fact that settles "served nothing" against "nothing measured it"
    // — see [modelAnswered].
    final gridTotal = ref.watch(gridPowerProvider).answered;
    final rows = rankModelUsage(
      models: models,
      nodes: nodes,
      gridTotal: gridTotal,
    );
    final window = answeredWindowLabel(gridTotal?.windowSeconds ?? 0);
    // No figures, no hero. "Busiest" is a claim about numbers, and a block
    // making it from an unmeasured list would be inventing one — the rows then
    // carry their ids alone, and the foot line says why they carry nothing else.
    final hero = rows.first.isActive ? rows.first : null;
    final rest = hero == null ? rows : rows.sublist(1);
    final figuresPending = gridTotal == null && loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PillPanelLabel(label: 'Models', trailing: '${rows.length}'),
        if (hero != null)
          _ModelHero(
            row: hero,
            share: outputShare(hero, gridTotal?.tokensOut ?? 0),
            window: window,
          ),
        if (rest.isNotEmpty) ...[
          _RestHeading(count: rest.length, under: hero != null),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _restMaxHeight),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: rest.length,
              itemBuilder: (context, i) => _ModelRow(
                row: rest[i],
                // Bars here are drawn against the busiest of the *rest*, not
                // against the grid: normalised to an 80% hero, four rows behind
                // it would each be the same 4px stub and the column would say
                // nothing. The hero states the absolute share in words above,
                // so this one is free to answer the question the list actually
                // asks — how these four compare with each other.
                peak: rest.first.tokensOut,
                loading: figuresPending,
              ),
            ),
          ),
        ],
        if (gridTotal != null)
          _ModelsFootLine(
            label: window.isEmpty ? 'All models' : 'All models · last $window',
            figures:
                '${formatCount(gridTotal.tokensIn)} in · '
                '${formatCount(gridTotal.tokensOut)} out',
          )
        // Not a skeleton: an older relay computes no rollup at all, and a bar
        // breathing forever over numbers that are never coming is a lie the
        // reader has no way to see through. While the first call is still out
        // the rows are already bars, so this line stays out of the way.
        else if (!figuresPending)
          const _ModelsFootLine(label: 'This relay reports no usage.'),
      ],
    );
  }
}

/// The model carrying the grid, as a block of its own: what it is called, its
/// share of the output, the three-way split of what it moved, and the three
/// facts that split cannot say — cache, speed, reach.
///
/// A [row] of null draws the same block as bars, at the same height. That is the
/// whole point of it being one widget: a skeleton written separately drifts from
/// the thing it stands in for, and this block is the tallest on the panel, so
/// any drift lands as the list jumping the moment the figures arrive.
class _ModelHero extends StatelessWidget {
  const _ModelHero({this.row, this.share, this.window = ''});

  final ModelUsage? row;

  /// Its share of everything the grid generated. Null when the grid generated
  /// nothing measurable — a percentage there would be a division by zero with a
  /// confident face on.
  final double? share;

  final String window;

  /// Where a model stops being one of the busy ones and becomes the one the grid
  /// runs on. Half the output is the honest line for that claim; below it the
  /// block still leads the list and says only that.
  static const double _carryingShare = 0.5;

  /// The block's own type, fixed here so the skeleton's bars can occupy exactly
  /// the line boxes the text will.
  static const double _idSize = 13;
  static const double _shareSize = 15;
  static const double _capSize = 10.5;
  static const double _statSize = 13;
  static const double _statLabelSize = 9.5;
  static const double _footSize = 11;
  static const double _lineHeight = 1.25;

  static double _box(double fontSize) => fontSize * _lineHeight;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final model = row;
    final lead = (share ?? 0) >= _carryingShare
        ? 'Carrying this grid'
        : 'Most used';
    final caption = window.isEmpty ? lead : '$lead · last $window';
    final detail = model == null ? '' : heroDetailLine(model);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        // `inset`, not another raised fill: this block sits *inside* the panel's
        // own lifted surface, and a second `surfaceFill` on top of it reads as a
        // card that came loose. Measured 1.09:1 against the panel in dark and
        // 1.073:1 in light — the pair the design system reserves for exactly
        // this nesting, and no use at all directly on the page.
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _box(_shareSize),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: model == null
                      ? const _Bar(widthFactor: 0.62, height: 10)
                      : _ModelIdText(
                          id: model.id,
                          fontSize: _idSize,
                          weight: AppFont.medium,
                        ),
                ),
                const SizedBox(width: 9),
                if (model == null)
                  const _Bar(width: 34, height: 11)
                else if (share case final value?)
                  Text(
                    formatShare(value),
                    style: TextStyle(
                      fontSize: _shareSize,
                      height: _lineHeight,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      // `accentOnSurface`, never `accent`: the flat brand blue
                      // reaches only 2.6:1 on a dark surface, and this is the
                      // one figure on the panel drawn in colour.
                      color: AppPalette.accentOnSurface,
                      fontFeatures: AppFont.tabularFigures,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: _box(_capSize) + 2,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: model == null
                  ? const _Bar(width: 96, height: 7)
                  : Text(
                      caption.toUpperCase(),
                      style: TextStyle(
                        fontSize: _capSize,
                        height: _lineHeight,
                        fontWeight: AppFont.medium,
                        letterSpacing: 0.4,
                        color: AppPalette.textFaint,
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 9),
            child: model == null
                // One bar, not three: the split's *shape* is the thing that
                // isn't known yet, and three placeholder legs would be a made-up
                // ratio drawn at full confidence.
                ? const _Bar(height: _TokenSplitBar.height, radius: 2)
                : _TokenSplitBar(
                    fresh: model.freshInputTokens,
                    cached: model.tokensCached,
                    out: model.tokensOut,
                  ),
          ),
          Row(
            children: [
              _HeroStat(
                value: model == null
                    ? null
                    : formatCount(model.freshInputTokens),
                label: 'FRESH IN',
                swatch: _TokenSplitBar.freshColor,
              ),
              _HeroStat(
                value: model == null ? null : formatCount(model.tokensCached),
                label: 'CACHED',
                swatch: _TokenSplitBar.cachedColor,
              ),
              _HeroStat(
                value: model == null ? null : formatCount(model.tokensOut),
                label: 'OUT',
                swatch: _TokenSplitBar.outColor,
              ),
              _HeroStat(
                value: model == null ? null : formatCount(model.requests),
                label: 'REQ',
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: Divider(height: 1, color: AppCard.insetHair),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              height: _box(_footSize),
              child: model == null
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: _Bar(widthFactor: 0.7, height: 7),
                    )
                  : Text(
                      // Never empty in practice — a hero exists only where
                      // something was measured — but a model answered by a node
                      // that has since gone offline can lose its last clause,
                      // and the line box is held either way.
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _footSize,
                        height: _lineHeight,
                        color: AppPalette.textFaint,
                        fontFeatures: AppFont.tabularFigures,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the hero's four figures, with the swatch that ties it to its leg of
/// the bar above. [value] of null draws it as a bar, keeping the label — the
/// label is structure, known before the call goes out, and blanking it would
/// throw away something the panel already has.
class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label, this.swatch});

  final String? value;
  final String label;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _ModelHero._box(_ModelHero._statSize),
            child: value == null
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: _Bar(width: 34, height: 10),
                  )
                : Text(
                    value!,
                    style: TextStyle(
                      fontSize: _ModelHero._statSize,
                      height: _ModelHero._lineHeight,
                      fontWeight: AppFont.medium,
                      letterSpacing: -0.2,
                      color: AppPalette.textPrimary,
                      fontFeatures: AppFont.tabularFigures,
                    ),
                  ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (swatch case final colour?) ...[
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: _ModelHero._statLabelSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: AppPalette.textFaint,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What one model moved, as one bar: fresh input, cached prefill, output.
///
/// **Three legs that sum to the model's whole traffic**, which is why the first
/// is `freshInputTokens` and not `tokensIn`: input *includes* the cached share
/// (see [AnsweredTokens]), so a bar drawn from `in | cached | out` would draw
/// the cache twice and overstate every busy model. The same reason the token
/// panel's three rows add up to their own grid.
///
/// Its own widget rather than [MemorySplitBar]: that one splits a total between
/// an unknown number of *machines* and carries a "+N more" bucket, while this is
/// three fixed legs with a fixed legend. What it does borrow is the lesson that
/// bar learned — slices butt together with no gap, and no leg is drawn thinner
/// than [_minLeg], because a 0.4% cache share of a 300px bar is otherwise a
/// sliver indistinguishable from a rendering seam.
class _TokenSplitBar extends StatelessWidget {
  const _TokenSplitBar({
    required this.fresh,
    required this.cached,
    required this.out,
  });

  final int fresh;
  final int cached;
  final int out;

  static const double height = 4;

  /// The narrowest a leg may be drawn while it carries anything at all.
  ///
  /// Six, the floor [MemorySplitBar] arrived at, and for a reason re-measured on
  /// this panel rather than inherited: a real grid answers agent traffic, so it
  /// reads about a hundred tokens for every one it writes — 136M fresh and 353M
  /// cached against 4.8M out, on the grid this was built against. Output is
  /// **0.97%** of that model's traffic, which is 2.9px of a 302px bar: the one
  /// leg the whole panel ranks by, drawn as the seam between the other two. The
  /// floor over-states it on purpose — presence beats precision at this size,
  /// and the figure under the bar carries the exact number anyway.
  static const double _minLeg = 6;

  /// The legs' colours, measured against [AppCard.inset] in both themes —
  /// fresh 3.95 light / 4.19 dark, cached 3.11 / 3.46, out 5.14 / 5.75 — all
  /// clear of the 3:1 that WCAG 1.4.11 asks of a graphic that carries meaning.
  /// Leg *against leg* is a different question and does not reach 3:1 at any
  /// choice of three colours readable on one ground; what separates them is hue,
  /// plus the swatch each figure below the bar carries.
  ///
  /// Distinct hues rather than three shades of the accent, the rule the memory
  /// bar arrived at: neighbouring legs a few pixels tall are told apart by hue,
  /// not by lightness. Cached is the grey on purpose — it is the leg that costs
  /// almost nothing, and a loud colour would argue otherwise.
  static const Color freshColor = Color(0xFF8B5CF6);
  static Color get cachedColor => AppPalette.textFaint;
  static Color get outColor => AppPalette.accentOnSurface;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final legs = <(int, Color)>[
      (fresh, freshColor),
      (cached, cachedColor),
      (out, outColor),
    ];
    final total = legs.fold<int>(0, (sum, leg) => sum + math.max(leg.$1, 0));
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final widths = _legWidths(legs, total, constraints.maxWidth);
            return Row(
              // Stretch, or each leg takes its minimum height and the bar
              // renders as an empty strip — a failure a widget test that only
              // asserts the legs exist cannot see.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < legs.length; i++)
                  if (widths[i] > 0)
                    SizedBox(
                      width: widths[i],
                      child: ColoredBox(color: legs[i].$2),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Widths for the legs of a bar [totalWidth] wide: proportional, but never
  /// below [_minLeg] for a leg that carries anything. What the floor grants is
  /// taken back from the legs above it in proportion, so the row still sums to
  /// the bar rather than overflowing it.
  List<double> _legWidths(
    List<(int, Color)> legs,
    int total,
    double totalWidth,
  ) {
    if (total <= 0 || totalWidth <= 0) {
      return [for (final _ in legs) 0];
    }
    final raw = [
      for (final leg in legs) math.max(leg.$1, 0) / total * totalWidth,
    ];
    var debt = 0.0;
    for (var i = 0; i < raw.length; i++) {
      if (legs[i].$1 > 0 && raw[i] < _minLeg) {
        debt += _minLeg - raw[i];
        raw[i] = _minLeg;
      }
    }
    if (debt <= 0) return raw;
    final donorTotal = [
      for (var i = 0; i < raw.length; i++)
        if (raw[i] > _minLeg) raw[i],
    ].fold<double>(0, (sum, w) => sum + w);
    // Every leg is at the floor — a bar too narrow to split at all. Share it
    // equally rather than letting the row overflow its own width.
    if (donorTotal <= 0) {
      return [for (var i = 0; i < raw.length; i++) totalWidth / raw.length];
    }
    return [
      for (final w in raw)
        if (w > _minLeg) w - debt * (w / donorTotal) else w,
    ];
  }
}

/// The heading over the models that are not the hero.
class _RestHeading extends StatelessWidget {
  const _RestHeading({required this.count, required this.under});

  final int count;

  /// Whether a hero sits above it. Without one these rows are the whole list,
  /// and calling them "others" would be othering them from nothing.
  final bool under;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final label = TextStyle(
      fontSize: 9.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppPalette.textFaint,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 13, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(under ? 'OTHERS · $count' : 'SERVING', style: label),
          ),
          // The column key, over the two figures each row ends with. Written
          // once here rather than as a unit beside every number: a column of
          // repeated units is a column the eye has to read past to reach what
          // differs.
          SizedBox(
            width: _ModelRow.inWidth,
            child: Text('IN', style: label, textAlign: TextAlign.right),
          ),
          const SizedBox(width: _ModelRow.gap + _ModelRow.barWidth),
          SizedBox(
            width: _ModelRow.outWidth,
            child: Text('OUT', style: label, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

/// One model that is not the hero: its id, what it read, how it compares with
/// its neighbours, and what it generated.
///
/// Only two of the four figures. Cache and requests are the hero's business —
/// on a model at 0.4% of the grid they are detail nobody is comparing, and the
/// width they would cost comes straight out of the id, which is the one thing
/// every row is read for.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.row,
    required this.peak,
    required this.loading,
  });

  final ModelUsage row;

  /// The largest output among the rows this one is listed with — the bar's
  /// denominator. Zero where nothing in the list generated anything, which
  /// leaves every bar empty rather than dividing by it.
  final int peak;

  /// Whether the figures are still on their way, as opposed to absent.
  final bool loading;

  static const double inWidth = 46;
  static const double barWidth = 34;
  static const double outWidth = 50;
  static const double gap = 9;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A media capability (`comfyui:*`) generates no tokens, so its measured zero
    // is true and useless — it would read as an idle model rather than one this
    // column simply does not describe.
    final media = mediaCapabilityLabel(row.id);
    final measured = row.answered != null && media == null;
    final fraction = peak <= 0 ? 0.0 : row.tokensOut / peak;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: _ModelIdText(
              id: row.id,
              fontSize: 12.5,
              // Not dimmed while the figures are still out: "this model did
              // nothing" is a conclusion, and the panel has not reached it yet.
              dim: !row.isActive && !loading,
            ),
          ),
          if (media case final label?) ...[
            const SizedBox(width: gap),
            PillPanelBadge(label: label),
          ],
          const SizedBox(width: gap),
          SizedBox(
            width: inWidth,
            child: loading
                ? const Align(
                    alignment: Alignment.centerRight,
                    child: _Bar(width: 32, height: 8),
                  )
                : _Figure(
                    text: measured ? formatCount(row.tokensIn) : '—',
                    strong: false,
                    dim: !row.isActive,
                  ),
          ),
          const SizedBox(width: gap),
          SizedBox(
            width: barWidth,
            child: loading || !measured
                ? const SizedBox.shrink()
                : _RowBar(fraction: fraction),
          ),
          const SizedBox(width: gap),
          SizedBox(
            width: outWidth,
            child: loading
                ? const Align(
                    alignment: Alignment.centerRight,
                    child: _Bar(width: 36, height: 8),
                  )
                : _Figure(
                    text: measured ? formatCount(row.tokensOut) : '—',
                    strong: true,
                    dim: !row.isActive,
                  ),
          ),
        ],
      ),
    );
  }
}

/// A row's figure: the output in ink, everything beside it a step back, so the
/// column the list is ordered by is the one the eye lands on.
class _Figure extends StatelessWidget {
  const _Figure({required this.text, required this.strong, required this.dim});

  final String text;
  final bool strong;

  /// Whether this model did nothing in the window. Its zeros stay legible but
  /// stop competing with the rows that did something.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: strong ? 12.5 : 11.5,
        fontWeight: strong && !dim ? AppFont.medium : FontWeight.w400,
        letterSpacing: strong ? -0.2 : 0,
        color: dim
            ? AppPalette.textFaint
            : strong
            ? AppPalette.textPrimary
            : AppPalette.textSecondary,
        fontFeatures: AppFont.tabularFigures,
      ),
    );
  }
}

/// A row's share bar — how this model compares with the others listed beside it.
class _RowBar extends StatelessWidget {
  const _RowBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(1.5),
      child: SizedBox(
        height: 3,
        child: ColoredBox(
          color: AppSurface.recess,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: ColoredBox(color: AppPalette.accentOnSurface),
          ),
        ),
      ),
    );
  }
}

/// A model id, set to be *scanned*: the provider prefix a step back, the tail
/// pinned, and only the middle allowed to ellipsize.
///
/// Plain ellipsis cuts from the right, which is where a model id keeps the part
/// that distinguishes it — `NVIDIA-Nemotron-3.5-Lightning-3…` loses the size and
/// the version, the two facts the name was carrying.
class _ModelIdText extends StatelessWidget {
  const _ModelIdText({
    required this.id,
    required this.fontSize,
    this.weight,
    this.dim = false,
  });

  final String id;
  final double fontSize;
  final FontWeight? weight;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final parts = splitModelId(id);
    final base = TextStyle(
      fontFamily: AppFont.mono,
      fontFamilyFallback: AppFont.monoFallback,
      fontSize: fontSize,
      fontWeight: weight ?? FontWeight.w500,
      letterSpacing: -0.1,
      color: dim ? AppPalette.textSecondary : AppPalette.textPrimary,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (parts.org.isNotEmpty)
          Text(
            parts.org,
            // The half of the id that repeats down the column, at the weight
            // repetition deserves.
            style: base.copyWith(
              fontWeight: FontWeight.w400,
              color: AppPalette.textFaint,
            ),
          ),
        Flexible(
          child: Text(
            parts.head,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
        if (parts.tail.isNotEmpty) Text(parts.tail, style: base),
      ],
    );
  }
}

/// The panel's last line: what the whole grid moved, or why it can't say.
class _ModelsFootLine extends StatelessWidget {
  const _ModelsFootLine({required this.label, this.figures});

  final String label;
  final String? figures;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: AppPalette.divider),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppPalette.textFaint,
                    ),
                  ),
                ),
                if (figures case final text?)
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppPalette.textSecondary,
                      fontFeatures: AppFont.tabularFigures,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The panel before its first payload: the heading, the hero and four rows, all
/// as bars.
///
/// The heading is a bar too, because the count is the one thing this state
/// cannot know — printing "MODELS 0" over a stack of placeholder rows would be
/// the panel contradicting itself. The rows fade down the column so the block
/// reads as "more below" rather than as a list that happens to hold four, and
/// their widths differ so a stack of bars doesn't read as a grey slab.
class _ModelsSkeleton extends StatelessWidget {
  const _ModelsSkeleton();

  static const List<double> _widths = [0.56, 0.42, 0.64, 0.38];

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          height: 15,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Skeleton.text(width: 78, height: 8),
          ),
        ),
        const _ModelHero(),
        const Padding(
          padding: EdgeInsets.only(top: 13, bottom: 4),
          child: SizedBox(
            height: 12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Skeleton.text(width: 56, height: 7),
            ),
          ),
        ),
        for (var i = 0; i < _widths.length; i++)
          Opacity(
            opacity: 1 - (i / _widths.length) * 0.65,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(child: _Bar(widthFactor: _widths[i], height: 9)),
                  const SizedBox(width: _ModelRow.gap),
                  const SizedBox(
                    width: _ModelRow.inWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _Bar(width: 32, height: 8),
                    ),
                  ),
                  const SizedBox(width: _ModelRow.gap),
                  const SizedBox(
                    width: _ModelRow.barWidth,
                    child: _Bar(height: 3, radius: 1.5),
                  ),
                  const SizedBox(width: _ModelRow.gap),
                  const SizedBox(
                    width: _ModelRow.outWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _Bar(width: 36, height: 8),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A placeholder bar, sized either to a fixed width or to a fraction of its row.
///
/// A thin wrapper over [Skeleton] so this file can write both without the
/// `FractionallySizedBox` dance at every call site — the breath, the colour and
/// the Reduce Motion behaviour are all still [Skeleton]'s.
class _Bar extends StatelessWidget {
  const _Bar({this.width, this.widthFactor, this.height = 9, this.radius = 4});

  final double? width;
  final double? widthFactor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (widthFactor case final factor?) {
      return SkeletonLine(widthFactor: factor, height: height);
    }
    return Skeleton(width: width, height: height, radius: radius);
  }
}
