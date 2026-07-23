import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/grid_overview_provider.dart';
import 'detail_widgets.dart';
import '../logic/node_display.dart';

/// The overview's prose face — headings, subtitles, labels, chips, node names.
/// Shared by the card sections and these widgets so the two files agree on one
/// token (no duplicate literal). See [AppFont] for why prose is *not* mono here.
/// Getters, not consts: [AppFont] resolves the user's chosen family at read
/// time, and a const would freeze whichever font was set when the library
/// loaded.
TextStyle get kGridText => TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
);

/// The face for a string the user is going to copy — a model id. Mono earns its
/// place here and nowhere else on this surface: these get pasted into a config
/// or a curl, so `l`/`1` and `0`/`O` have to stay apart.
TextStyle get kGridCode => TextStyle(
  fontFamily: AppFont.mono,
  fontFamilyFallback: AppFont.monoFallback,
);

/// A stat's headline number: sans, but with fixed-width digits so the value
/// doesn't reflow as it changes. See [AppFont.tabularFigures].
TextStyle get kGridNumeral => TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
  fontFeatures: AppFont.tabularFigures,
);

/// What the grid can do ("Chat", "Images") — a *statement about* the grid, not
/// something to click.
///
/// Unfilled, for the same reason [_Pill] is: it used to wear a filled capsule
/// with a rim, which is exactly what a button looks like, so "Chat" read as
/// something that would open a chat — and clicking it did nothing. The accent
/// glyph carries it; the capsule was only ever pretending.
class CapabilityChip extends StatelessWidget {
  const CapabilityChip({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppControl.iconSizeChip, color: AppPalette.accent),
        const SizedBox(width: 5),
        Text(
          label,
          style: kGridText.copyWith(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// The grid's headline facts, as one line: models, nodes, uptime.
///
/// It used to be a ~90px card of three big numbers, which mostly restated the
/// screen it sat on — "MODELS 9" directly above a list of nine countable models,
/// "NODES 2" above the Nodes section — and pushed the pane's one real action
/// ("Use this grid") toward the fold to do it. Only uptime carried anything new.
/// So the numbers stay and the furniture goes: a line reads just as fast and
/// costs a fifth of the height.
///
/// Still hidden on a grid that serves nothing yet: "0 models, 0 nodes" is noise
/// a new user has to decode, and it buries the setup card telling them what to
/// do next.
class StatsBar extends ConsumerWidget {
  const StatsBar({super.key, required this.stats});
  final GridStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uptime = stats.uptimePct == null
        ? '—'
        : '${_trim(stats.uptimePct!)}%';
    // The overview's own `stats.models` can lag at 0 when the relay doesn't
    // detail its models — trust the list we actually resolved (overview or
    // `/models`) whenever it has entries, so the headline matches the section.
    final resolved = ref.watch(gridModelsProvider).length;
    final models = resolved > 0 ? resolved : stats.models;
    if (models == 0 && stats.nodes == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 7,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Fact(value: '$models', unit: models == 1 ? 'model' : 'models'),
          const _FactDot(),
          _Fact(
            value: '${stats.nodes}',
            unit: stats.nodes == 1 ? 'node' : 'nodes',
          ),
          const _FactDot(),
          _Fact(value: uptime, unit: 'uptime'),
        ],
      ),
    );
  }
}

/// One fact on the meta line: the number in ink, its unit in a softer grey, so
/// the values still stand out from the words at a glance.
class _Fact extends StatelessWidget {
  const _Fact({required this.value, required this.unit});
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            // Tabular: these sit in a line that reflows as the grid's numbers
            // change, and shifting digit widths would jitter the whole row.
            style: kGridNumeral.copyWith(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
          TextSpan(
            text: ' $unit',
            style: kGridText.copyWith(
              fontSize: 12.5,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The separator between two facts.
class _FactDot extends StatelessWidget {
  const _FactDot();

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Text(
      '·',
      style: kGridText.copyWith(fontSize: 12.5, color: AppPalette.textFaint),
    );
  }
}

/// Section heading: a bold title over a softer subtitle, with an optional count
/// beside the title.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.count,
  });
  final String title;
  final String subtitle;

  /// How many rows the section holds, shown beside the title. Null to omit.
  final int? count;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: kGridText.copyWith(
                fontSize: 19,
                // Semibold: this heads a section *within* a page, so it only has
                // to out-rank the medium row titles under it — not the page
                // title above it.
                fontWeight: AppFont.semibold,
                letterSpacing: -0.2,
                color: AppPalette.textPrimary,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 8),
              Text(
                '$count',
                style: kGridNumeral.copyWith(
                  fontSize: 13,
                  color: AppPalette.textFaint,
                ),
              ),
            ],
          ],
        ),
        // Omitted entirely when empty, rather than rendered as a blank line: an
        // empty Text still occupies its line box, so a heading that has nothing
        // to add pushed everything below it down by a line it never used. Some
        // headings genuinely need no gloss — three labelled pictures of a theme
        // explain themselves.
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: kGridText.copyWith(
              fontSize: 13,
              height: 1.34,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// One card holding a stack of rows, hairline-separated — the shape macOS gives
/// a uniform list.
///
/// The models used to be one card each: nine rims, nine fills and eight gaps
/// for one homogeneous list, which read as nine islands rather than one thing
/// with nine entries. A single card says "these are the same kind of row" and
/// lets the ids down the left do the scanning work.
class TileGroup extends StatelessWidget {
  const TileGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: EdgeInsets.zero,
      // The card's rim already rounds the corners; without this the first and
      // last rows' hover fill would square them off again.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: AppCard.insetHair),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One compact model row: modality glyph, copyable id, kind pill, Copy action.
///
/// Tracks hover so the row's Copy chip can stay quiet until the pointer is on
/// it — see [_CopyChip].
class ModelTile extends StatefulWidget {
  const ModelTile({super.key, required this.model});
  final OverviewModel model;

  @override
  State<ModelTile> createState() => _ModelTileState();
}

class _ModelTileState extends State<ModelTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    final model = widget.model;
    // A comfyui media capability (image/video) can surface in the model list —
    // label it as media with an image/video glyph instead of the default
    // "Chat". See [mediaCapabilityLabel].
    final mediaLabel = mediaCapabilityLabel(model.id);
    final pill =
        mediaLabel ?? (model.modality == null ? null : _cap(model.modality!));
    final icon = mediaLabel == null
        ? Icons.chat_bubble_outline
        : isVideoCapability(model.id)
        ? Icons.movie_outlined
        : Icons.image_outlined;
    // A row inside [TileGroup] now, not a card of its own — so the hover fill
    // is the row's own, and it paints edge to edge.
    //
    // Animated, at the app's hover timing: every other hovering surface in the
    // app eases its fill in, and this row was the one left snapping between two
    // colours. Over a stack of nine rows a hard cut reads as the list flinching
    // as the pointer crosses it.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.hover,
        curve: AppMotion.curve,
        color: _hovered ? AppSurface.hoverFill : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              _TileIcon(icon: icon, accent: true, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  model.id,
                  overflow: TextOverflow.ellipsis,
                  // Mono: this is the string the Copy chip puts on the
                  // clipboard.
                  style: kGridCode.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              if (pill != null) ...[
                const SizedBox(width: 10),
                _Pill(text: pill),
              ],
              const SizedBox(width: 10),
              _CopyChip(id: model.id, active: _hovered),
            ],
          ),
        ),
      ),
    );
  }
}

/// One node row — engine, device class, VRAM, role, concurrency, throughput.
class NodeTile extends StatelessWidget {
  const NodeTile({super.key, required this.node});
  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    final media = nodeIsMedia(node);
    final vram = nodeVramLabel(node);
    final specs = <String>[
      nodeEngineLabel(node.engine),
      if ((node.deviceClass ?? '').isNotEmpty) node.deviceClass!.toUpperCase(),
      ?vram,
      nodeRoleSummary(node),
      if ((node.maxConcurrency ?? 0) > 1) '${node.maxConcurrency} parallel',
      if (node.throughputTokS != null) '~${node.throughputTokS!.round()} tok/s',
    ].where((s) => s.isNotEmpty).toList();
    // A row inside [TileGroup], like [ModelTile] — the card is the group's.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          _TileIcon(
            icon: media ? Icons.auto_awesome_outlined : Icons.dns_outlined,
            accent: false,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.name,
                  overflow: TextOverflow.ellipsis,
                  style: kGridText.copyWith(
                    fontSize: 14,
                    fontWeight: AppFont.medium,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  // Specs carry numbers (VRAM, tok/s, parallelism) that read as
                  // a column down a stack of nodes — tabular digits keep them
                  // from wobbling, without dressing the line as code.
                  specs.join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: kGridNumeral.copyWith(
                    fontSize: 12,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _OnlineTag(online: node.online),
        ],
      ),
    );
  }
}

/// Compact online/offline status, dot plus word, on a node row.
class _OnlineTag extends StatelessWidget {
  const _OnlineTag({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    final color = online ? AppPalette.online : AppPalette.offline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 8),
        const SizedBox(width: 6),
        Text(
          online ? 'Online' : 'Offline',
          style: kGridText.copyWith(
            fontSize: 12,
            fontWeight: AppFont.medium,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Modality/media glyph container with optional accent background.
class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.accent, this.size = 32});
  final IconData icon;
  final bool accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent ? AppPalette.accent : AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        icon,
        size: size * 0.5,
        color: accent ? Colors.white : AppPalette.textSecondary,
      ),
    );
  }
}

/// The kind label ("Chat", "Images") on a model tile — a *statement about* the
/// model, not something to click.
///
/// Deliberately unfilled. It used to wear the same grey capsule as the Copy
/// button sitting 10px to its right, and two grey capsules side by side read as
/// a pair of buttons — so "Chat" looked like it would open a chat, and clicking
/// it did nothing. A label earns no fill; only the button next to it does.
class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        text,
        style: kGridText.copyWith(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}

/// Small "Copy" pill on a model tile — copies the model's exact id.
///
/// Quiet at rest, accent when its row is hovered ([active]). A stack of model
/// rows is read by scanning the *ids* down the left; painting every row's chip
/// in accent puts a column of the brightest colour on the surface down the right
/// edge, pulling the eye off the thing being scanned and flattening the
/// hierarchy — the chip ends up louder than its own subject. Hover is what says
/// "this row", so that's what earns the colour.
class _CopyChip extends StatelessWidget {
  const _CopyChip({required this.id, required this.active});
  final String id;
  final bool active;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    final fg = active ? AppPalette.accent : AppPalette.textFaint;
    // Fill, glyph and label all cross on the row's own timing — the chip lights
    // up *with* the row it belongs to rather than a beat apart from it.
    return AnimatedContainer(
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: active ? AppPalette.cardBgHover : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => copyToClipboard(context, id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<Color?>(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  tween: ColorTween(end: fg),
                  builder: (context, color, _) => Icon(
                    Icons.copy_rounded,
                    size: AppControl.iconSizeChip,
                    color: color,
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedDefaultTextStyle(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  style: kGridText.copyWith(
                    fontSize: 11,
                    fontWeight: AppFont.medium,
                    letterSpacing: 0.4,
                    color: fg,
                  ),
                  child: const Text('Copy'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading/error placeholder for the overview pane.
class OverviewMessage extends StatelessWidget {
  const OverviewMessage({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens — follow theme flips. Without this the
    // widget keeps whichever palette it first built with; on a static screen
    // (Appearance) nothing else rebuilds it, so the flip never lands.
    AppTheme.watch(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppPalette.textFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: kGridText.copyWith(
                fontSize: 13,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Drop a trailing `.0` so `99.9 → "99.9"`, `8.0 → "8"`, `0.0 → "0"`.
String _trim(num v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';
