part of 'command_palette.dart';

/// One row: what it is, what it would open, and the number that opens it.
class CommandRow extends StatelessWidget {
  const CommandRow({
    super.key,
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final CommandItem item;

  /// Position in the whole list — the first nine get a ⌘n of their own.
  final int index;

  /// The row ⏎ would open. Highlighted, not "checked": it's where you are, not
  /// something you chose.
  final bool selected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? AppSurface.selectedFill : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  commandIcon(item),
                  size: 16,
                  color: AppPalette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (item.detail.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      item.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textFaint,
                      ),
                    ),
                  ),
                ],
                if (index < _digitKeys.length) ...[
                  const SizedBox(width: 10),
                  _Shortcut(label: '⌘${index + 1}'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The key that runs this row, drawn as a key.
class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: AppPalette.textFaint,
            fontSize: 11.5,
            fontWeight: AppFont.medium,
          ),
        ),
      ),
    );
  }
}

/// What each kind of row does, at a glance.
IconData commandIcon(CommandItem item) => switch (item) {
  OpenChatCommand() => Icons.chat_bubble_outline_rounded,
  NewChatCommand() => Icons.edit_outlined,
  OpenTaskCommand() => Icons.schedule_rounded,
  AddProjectCommand() => Icons.create_new_folder_outlined,
  OpenSettingsCommand() => Icons.settings_outlined,
  SendFeedbackCommand() => Icons.campaign_outlined,
  GoToCommand(:final section) => section.icon,
};
