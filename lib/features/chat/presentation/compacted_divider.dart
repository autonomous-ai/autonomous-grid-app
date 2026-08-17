import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/commands/chat_compaction.dart';

/// The line across the transcript where `/compact` folded the context up.
///
/// It sits *in* the conversation because that is where the fact lives: the
/// messages above are still there to read, and this says the assistant is
/// reading a summary of them instead. A toast alone would have told the user
/// once, at the moment they were least likely to need it again.
class CompactedDivider extends StatelessWidget {
  const CompactedDivider({super.key, required this.compaction});

  final ChatCompaction compaction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Divider(color: AppPalette.divider, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.unfold_less_rounded,
                  size: 15,
                  color: AppPalette.textFaint,
                ),
                const SizedBox(width: 6),
                // Bounded: a desktop window narrows, and a label that laid the
                // whole sentence out in one line would push the rules off both
                // ends of it.
                Flexible(
                  child: Text(
                    compactedDividerLabel(compaction),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: AppPalette.divider, height: 1)),
        ],
      ),
    );
  }
}
