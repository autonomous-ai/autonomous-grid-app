import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/commands/chat_command.dart';

/// The badge inside the composer naming the command the line will run.
///
/// Once a space follows `/compact` the `/` menu closes and the line reads as
/// an ordinary message (see [activeComposerCommand]) — a user writing the
/// summary's focus could not tell it from a prompt they were sending. This says
/// which, in the composer itself and for as long as the argument is being
/// written: press Send and *this* runs, not a message. Tinted with the accent so it reads as a mode the
/// line is in rather than text in it.
class ComposerCommandChip extends StatelessWidget {
  const ComposerCommandChip({super.key, required this.command});

  final ChatCommand command;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads accent tokens — follow theme flips
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppSurface.accentWash,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _commandIcon(command),
                  size: 13,
                  color: AppPalette.accentOnSurface,
                ),
                const SizedBox(width: 5),
                Text(
                  command.slash,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: AppPalette.accentOnSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // What pressing Send will do, in the command's own words — the same
          // line the `/` menu showed, so the promise doesn't change between
          // picking the command and finishing it.
          Flexible(
            child: Text(
              command.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The glyph for each command.
IconData _commandIcon(ChatCommand command) => switch (command) {
  ChatCommand.clear => Icons.add_comment_outlined,
  ChatCommand.compact => Icons.compress_rounded,
};
