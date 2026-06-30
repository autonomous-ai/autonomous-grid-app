import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';

/// A titled group of rows in the detail pane (e.g. "Endpoints", "Details").
class DetailSection extends StatelessWidget {
  const DetailSection(
      {super.key, required this.title, required this.children, this.trailing});

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
                style: const TextStyle(
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
        Container(
          decoration: BoxDecoration(
            color: AppPalette.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppPalette.divider),
          ),
          child: Column(children: _withDividers(children)),
        ),
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
  const AddressRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

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
                Text(value,
                    style: const TextStyle(
                        color: AppPalette.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 13)),
                const SizedBox(height: 2),
                Text(label,
                    style: const TextStyle(
                        color: AppPalette.textSecondary, fontSize: 11.5)),
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
          Text(label,
              style: const TextStyle(
                  color: AppPalette.textSecondary, fontSize: 13)),
          const Spacer(),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: AppPalette.textPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// A single "Owner" pill for grids the viewer owns, shown next to the grid name
/// in both the list and the detail header. Members/consumers get no badge —
/// owning a grid is the only distinction worth surfacing here.
class OwnerBadge extends StatelessWidget {
  const OwnerBadge({super.key, required this.network, this.onAccent = false});

  final NetworkCredential network;

  /// Render for an accent-filled (selected) row — swaps the teal pill for a
  /// white one that stays legible on the blue background, where teal muddies.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    if (network.role != NetworkRole.admin) return const SizedBox.shrink();
    return _BadgePill(
      label: network.roleLabel, // 'Owner'
      color: onAccent ? Colors.white : AppPalette.teal,
      compact: true,
      // On the blue selected row a faint white pill blends into the row and its
      // white text into the grid name — fill/outline it more so it stays a
      // distinct badge.
      fillAlpha: onAccent ? 0.24 : 0.16,
      borderAlpha: onAccent ? 0.7 : 0.45,
    );
  }
}

/// One rounded, tinted pill — the shared shape for role and visibility badges.
class _BadgePill extends StatelessWidget {
  const _BadgePill(
      {required this.label,
      required this.color,
      this.compact = false,
      this.fillAlpha = 0.16,
      this.borderAlpha = 0.45});

  final String label;
  final Color color;
  final bool compact;
  final double fillAlpha;
  final double borderAlpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8, vertical: compact ? 1 : 3),
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
            letterSpacing: 0.2),
      ),
    );
  }
}

/// A compact icon button that copies [value] to the clipboard and toasts.
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
      onPressed: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
        );
      },
    );
  }
}
