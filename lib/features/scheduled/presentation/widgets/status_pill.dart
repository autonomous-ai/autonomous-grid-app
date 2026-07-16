import 'package:flutter/material.dart';

/// A small text badge in a tinted capsule — the status a task is in, or "new
/// results", said in a word rather than a bare colour.
///
/// The tint is derived from [color] so a caller only has to pass the semantic
/// colour once; the pill fills at low alpha behind text at full strength, which
/// keeps it legible on both the light and dark grounds the app runs on.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;

  /// An optional leading glyph (a check for "new results", say). Most status
  /// pills lean on the word alone, so it defaults off.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? 8 : 6, 2, 8, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1.1,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
