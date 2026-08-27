import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/commands/chat_command.dart';

/// The `/` menu above the composer: the app's own commands, filtered by what
/// has been typed after the slash.
///
/// Picking one runs it.
///
/// Presentational: the match is [matchingChatCommands], tested on its own.
class CommandSlashMenu extends StatelessWidget {
  const CommandSlashMenu({
    super.key,
    required this.query,
    required this.onPick,
  });

  /// The text after the leading `/`; empty shows every command.
  final String query;

  final ValueChanged<ChatCommand> onPick;

  @override
  Widget build(BuildContext context) {
    final matches = matchingChatCommands(query);
    // Nothing of ours matches, so the user is writing something else that
    // happens to start with a slash — an agent's own command, a path. Showing
    // "no match" over the composer would be the app interrupting a sentence.
    if (matches.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final command in matches)
            _CommandRow(command: command, onTap: () => onPick(command)),
        ],
      ),
    );
  }
}

/// One command: its slash name, what it does, and the line under it saying what
/// that means for the chat in front of you.
class _CommandRow extends StatefulWidget {
  const _CommandRow({required this.command, required this.onTap});

  final ChatCommand command;
  final VoidCallback onTap;

  @override
  State<_CommandRow> createState() => _CommandRowState();
}

class _CommandRowState extends State<_CommandRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final command = widget.command;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered ? AppPalette.cardBgHover : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      command.slash,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: AppFont.medium,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        command.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  command.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
