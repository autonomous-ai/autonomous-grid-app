import 'package:flutter/material.dart';

/// A clearly-visible failure box: error-coloured, with an icon and selectable
/// text, scrollable so a long CLI message stays legible. Shared by the login
/// and onboarding screens so failures read the same everywhere.
class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.message, this.maxHeight = 160});

  final String message;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                message,
                style: TextStyle(color: color, fontSize: 12.5, height: 1.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
