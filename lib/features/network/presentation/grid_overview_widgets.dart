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
const TextStyle kGridText = TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
);

/// The face for a string the user is going to copy — a model id. Mono earns its
/// place here and nowhere else on this surface: these get pasted into a config
/// or a curl, so `l`/`1` and `0`/`O` have to stay apart.
const TextStyle kGridCode = TextStyle(
  fontFamily: AppFont.mono,
  fontFamilyFallback: AppFont.monoFallback,
);

/// A stat's headline number: sans, but with fixed-width digits so the value
/// doesn't reflow as it changes. See [AppFont.tabularFigures].
const TextStyle kGridNumeral = TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
  fontFeatures: AppFont.tabularFigures,
);

/// A single capability chip: an accent icon plus its label.
class CapabilityChip extends StatelessWidget {
  const CapabilityChip({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppPalette.accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: kGridText.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stats bar showing Models / Nodes / Uptime headline numbers. Hidden on a grid
/// that serves nothing yet: "0 models, 0 nodes, 99.9% uptime" is noise a new
/// user has to decode, and it buries the one thing that matters there — the
/// setup card telling them what to do next.
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
    return GlassCard(
      child: IntrinsicHeight(
        child: Row(
          children: [
            _StatCell(label: 'MODELS', value: '$models'),
            const VerticalDivider(width: 1),
            _StatCell(label: 'NODES', value: '${stats.nodes}'),
            const VerticalDivider(width: 1),
            _StatCell(label: 'UPTIME', value: uptime),
          ],
        ),
      ),
    );
  }
}

/// One stat cell inside the stats bar: a small label over a large number.
class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: kGridText.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: AppPalette.textFaint,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kGridNumeral.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section heading: a bold title over a softer subtitle.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    required this.subtitle,
  });
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: kGridText.copyWith(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: AppPalette.textPrimary,
          ),
        ),
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
    );
  }
}

/// Thin glass-card wrapper used by model and node tiles.
class _TileCard extends StatelessWidget {
  const _TileCard({required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      style: GlassCardStyle.inset,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: child,
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: _TileCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            _TileIcon(icon: icon, accent: true, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                model.id,
                overflow: TextOverflow.ellipsis,
                // Mono: this is the string the Copy chip puts on the clipboard.
                style: kGridCode.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
            if (pill != null) ...[const SizedBox(width: 10), _Pill(text: pill)],
            const SizedBox(width: 10),
            _CopyChip(id: model.id, active: _hovered),
          ],
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
    return _TileCard(
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
                    fontWeight: FontWeight.w600,
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
            fontWeight: FontWeight.w600,
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
    final fg = active ? AppPalette.accent : AppPalette.textFaint;
    return Material(
      color: active ? AppPalette.cardBgHover : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => copyToClipboard(context, id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy_rounded, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(
                'Copy',
                style: kGridText.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: fg,
                ),
              ),
            ],
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
