import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../overlord_tokens.dart';

/// One dashboard column: a rounded, bordered surface with a dotted uppercase
/// header (label + optional trailing actions) over a body. Shared by all three
/// panels so GPUs, Storage, and the Orchestrator read identically.
class PanelFrame extends StatelessWidget {
  const PanelFrame({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
    this.dotColor = OverlordTokens.accent,
  });

  final String label;
  final Widget child;
  final Widget? trailing;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(label: label, dotColor: dotColor, trailing: trailing),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.label,
    required this.dotColor,
    required this.trailing,
  });

  final String label;
  final Color dotColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
      child: Row(
        children: [
          StatusDot(color: dotColor, size: 7),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: OverlordTokens.sublabel.copyWith(
                fontSize: 11.5,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}
