import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/composer_snippet.dart';

/// The runs of text picked out of files, riding on the next message.
///
/// **One chip for all of them**, unlike the file chips beside it. A selection is
/// not a thing with a name — five of them out of one file would be five chips
/// reading the same filename, and the row would say nothing except that the user
/// has been busy. What matters is *how many* and *what they say*, so the count
/// is on the chip and the text is a hover away.
class SnippetChip extends StatelessWidget {
  const SnippetChip({
    super.key,
    required this.snippets,
    required this.onRemove,
  });

  final List<ChatSnippet> snippets;

  /// Takes them all off. One action, because they arrived as one chip — picking
  /// a single selection back out of a stack of eight is a job for a list, and a
  /// list is more chrome than this deserves.
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (snippets.isEmpty) return const SizedBox.shrink();
    final radius = BorderRadius.circular(10);
    final count = snippets.length;

    return Tooltip(
      // The selections themselves, in the order they were added, each under the
      // file it came from. Long ones are cut here and not on the message: what
      // is on the hover is a reminder of what you picked, not the payload.
      message: [
        for (final snippet in snippets)
          // Named the way the message will name it — with the lines, where the
          // surface it came from knew them.
          '${snippet.name}${snippet.lineRange} — ${_preview(snippet.text)}',
      ].join('\n\n'),
      child: Material(
        color: AppPalette.cardBg,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: AppPalette.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.textQuote300,
                size: 16,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                count == 1 ? '1 selection' : '$count selections',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: AppFont.medium,
                ),
              ),
              _RemoveButton(onTap: onRemove, count: count),
            ],
          ),
        ),
      ),
    );
  }
}

/// The first few lines of a selection, with the newlines left in — a quote read
/// as one run-on line is unrecognisable as the code it came from.
String _preview(String text) {
  const maxLines = 4;
  const maxChars = 240;
  final lines = text.split('\n');
  final head = lines.take(maxLines).join('\n');
  final cut = head.length > maxChars ? '${head.substring(0, maxChars)}…' : head;
  return lines.length > maxLines ? '$cut\n…' : cut;
}

/// Takes the selections back off the message.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap, required this.count});

  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(7);
    return Tooltip(
      message: count == 1 ? 'Remove' : 'Remove all $count',
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        splashFactory: NoSplash.splashFactory,
        hoverColor: AppSurface.hoverFill,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: 14,
            color: AppPalette.textFaint,
            semanticLabel: 'Remove selections',
          ),
        ),
      ),
    );
  }
}
