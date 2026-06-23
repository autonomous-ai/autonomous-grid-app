import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';

/// A titled group of rows in the detail pane (e.g. "Endpoints", "Details").
class DetailSection extends StatelessWidget {
  const DetailSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppPalette.textFaint,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
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
          _CopyButton(value: value),
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

/// A small pill showing the viewer's role on a network (Provider / Consumer).
/// Provider is accented; consumer is muted.
class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.network, this.compact = false});

  final NetworkCredential network;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color =
        network.isProvider ? AppPalette.accent : AppPalette.textSecondary;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8, vertical: compact ? 1 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        network.roleLabel,
        style: TextStyle(
            color: color,
            fontSize: compact ? 10 : 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value});
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
