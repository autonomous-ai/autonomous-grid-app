import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';

/// A titled group of rows in the detail pane (e.g. "Endpoints", "Details").
class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;

  /// Optional action shown at the trailing edge of the title row (e.g. a help
  /// icon). Sits inline with the section heading.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Row(
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: AppPalette.textFaint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
              if (trailing != null) ...[const Spacer(), trailing!],
            ],
          ),
        ),
        GlassCard(child: Column(children: _withDividers(children))),
      ],
    );
  }

  List<Widget> _withDividers(List<Widget> rows) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      out.add(rows[i]);
      if (i != rows.length - 1) {
        out.add(const Divider(height: 1, indent: 14, endIndent: 14));
      }
    }
    return out;
  }
}

/// A monospace value row with a copy button — for URLs / IDs.
class AddressRow extends StatelessWidget {
  const AddressRow({
    super.key,
    required this.label,
    required this.value,
    this.maxLines,
  });

  final String label;
  final String value;

  /// When set, clamp the value to this many lines with an ellipsis — for long
  /// opaque values (e.g. an access token) the user copies rather than reads.
  /// `null` keeps the full value wrapping, the default for short URLs/IDs.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: maxLines,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          CopyIconButton(value: value),
        ],
      ),
    );
  }
}

/// A plain label → value row for the "Details" section.
class MetaRow extends StatelessWidget {
  const MetaRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// One grid pill in the shared compact shape, with the accent-row legibility
/// swap: white on the blue selected row (where the tint muddies), the tint
/// colour otherwise. One place so every grid badge looks identical.
Widget _gridPill(String label, Color color, {required bool onAccent}) =>
    _BadgePill(
      label: label,
      color: onAccent ? Colors.white : color,
      compact: true,
      fillAlpha: onAccent ? 0.24 : 0.16,
      borderAlpha: onAccent ? 0.7 : 0.45,
    );

/// The list badge: a single pill so the sidebar row stays compact — "Owner" if
/// the viewer owns the grid, else "Public" for a public grid they merely joined
/// (otherwise a grid the user doesn't own looks like it appeared for no reason),
/// else nothing. The detail header shows both at once via [GridBadges].
class GridBadge extends StatelessWidget {
  const GridBadge({super.key, required this.network, this.onAccent = false});

  final NetworkCredential network;

  /// Render for an accent-filled (selected) row — see [_gridPill].
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    if (network.role == NetworkRole.admin) {
      return _gridPill(network.roleLabel, AppPalette.teal, onAccent: onAccent);
    }
    if (network.isPublic) {
      return _gridPill(
        network.visibilityLabel,
        AppPalette.accent,
        onAccent: onAccent,
      );
    }
    return const SizedBox.shrink();
  }
}

/// The detail-header badges: the role pill ("Owner" for admins) plus, for a
/// public grid, a "Public" visibility pill beside it — so an owned public grid
/// reads "Owner  Public" and the visibility is clear at a glance. The header has
/// the room the compact list row lacks. Renders only the pills that apply.
class GridBadges extends StatelessWidget {
  const GridBadges({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    final pills = <Widget>[
      if (network.role == NetworkRole.admin)
        _gridPill(network.roleLabel, AppPalette.teal, onAccent: false),
      if (network.isPublic)
        _gridPill(network.visibilityLabel, AppPalette.accent, onAccent: false),
    ];
    if (pills.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }
}

/// One rounded, tinted pill — the shared shape for role and visibility badges.
class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.label,
    required this.color,
    this.compact = false,
    this.fillAlpha = 0.16,
    this.borderAlpha = 0.45,
  });

  final String label;
  final Color color;
  final bool compact;
  final double fillAlpha;
  final double borderAlpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: fillAlpha),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: borderAlpha)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10 : 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Copies [text] to the clipboard and shows a brief "Copied" toast. Shared by
/// every copy affordance so the behavior and the toast copy stay identical.
void copyToClipboard(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
  );
}

/// A compact, low-emphasis icon button that copies [value] — the corner
/// affordance for rows/panels where copying is secondary (URLs, IDs, snippets).
class CopyIconButton extends StatelessWidget {
  const CopyIconButton({super.key, required this.value});
  final String value;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.copy_rounded, size: 15),
      color: AppPalette.textSecondary,
      tooltip: 'Copy',
      visualDensity: VisualDensity.compact,
      onPressed: () => copyToClipboard(context, value),
    );
  }
}

/// A highlighted, accent-tinted "Copy" pill — for a card whose whole purpose is
/// copying one value (e.g. a media skill prompt), where the copy is the primary
/// action and should stand out instead of sitting as a faint corner icon.
class CopyButton extends StatelessWidget {
  const CopyButton({super.key, required this.value, this.label = 'Copy'});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: () => copyToClipboard(context, value),
      icon: const Icon(Icons.copy_rounded, size: AppControl.iconSize),
      label: Text(label),
      // Only the accent tint (fill/label/rim) is this button's own — it sits in
      // a card corner, so it stays on the compact scale; the rest is the theme.
      style: FilledButton.styleFrom(
        backgroundColor: AppPalette.accent.withValues(alpha: 0.16),
        foregroundColor: AppPalette.accent,
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
        side: BorderSide(color: AppPalette.accent.withValues(alpha: 0.5)),
      ),
    );
  }
}

/// A heading above a code block, with an optional caption (e.g. the file the
/// snippet belongs in). Shared by the app-connection guide.
class GuideLabel extends StatelessWidget {
  const GuideLabel(this.text, {super.key, this.caption});
  final String text;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption!,
                style: TextStyle(
                  color: AppPalette.textFaint,
                  fontSize: 11.5,
                  height: 1.3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A monospace, selectable code panel with a copy button in the corner. Shared
/// by the app-connection guide.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
            child: SelectableText(
              code,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
          Positioned(top: 2, right: 2, child: CopyIconButton(value: code)),
        ],
      ),
    );
  }
}
