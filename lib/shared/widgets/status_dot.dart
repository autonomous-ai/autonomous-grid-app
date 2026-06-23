import 'package:flutter/material.dart';

/// A small colored status dot with a soft glow — the online/offline indicator
/// used across the list and detail panes.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5),
        ],
      ),
    );
  }
}
