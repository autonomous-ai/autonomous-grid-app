import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/agent_catalog.dart';

/// An agent's bundled mark, drawn as its own image (not a tinted glyph) since
/// each is a real logo with its own colour.
///
/// Shared by everything that has to say *which agent* in a small space — the
/// picker, and the skill rows that show who holds a copy.
class AgentMark extends StatelessWidget {
  const AgentMark({super.key, required this.tool, this.size = 18});

  final AgentTool tool;
  final double size;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // the fallback glyph reads a palette token
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.asset(
        tool.iconAsset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // A missing/undeclared asset must not crash the screen — fall back to a
        // neutral glyph (agent_catalog_test guards the real assets in CI).
        errorBuilder: (_, _, _) => Icon(
          Icons.smart_toy_outlined,
          size: size,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
