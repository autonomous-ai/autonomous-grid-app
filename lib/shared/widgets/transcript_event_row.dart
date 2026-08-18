import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A line across the transcript for something that happened *to* the
/// conversation rather than something said in it — the context folded up, a
/// goal met, a repeating prompt stopped.
///
/// It sits in the conversation because that is where the fact lives, at the
/// point it happened: the messages around it are still there to read, and this
/// says what changed between them. The alternative the app used to run — a card
/// pinned over the composer until the user waved it away — told the news at the
/// moment it happened and then went on telling it for the rest of the day,
/// between the transcript and the box the user was typing in.
class TranscriptEventRow extends StatelessWidget {
  const TranscriptEventRow({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;

  /// One line, in the user's terms. Centred between two rules, so it reads as a
  /// marker in the conversation rather than another message in it.
  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Expanded(child: Divider(color: AppPalette.divider, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: AppPalette.textFaint),
                const SizedBox(width: 6),
                // Bounded: a desktop window narrows, and a label that laid the
                // whole sentence out in one line would push the rules off both
                // ends of it.
                Flexible(
                  child: Text(
                    label,
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
