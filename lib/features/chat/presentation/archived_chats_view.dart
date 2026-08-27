import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/layouts/reveal_chat.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/toast.dart';
import '../../projects/logic/project.dart';
import '../logic/archived_filter.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'chat_header.dart';

/// Settings › Archived chats: everything the user has filed away, with the
/// controls to find it again — search, a scope/project filter, a sort — and the
/// two ways out of the pile: put a chat back, or delete it for good.
///
/// Archiving is reversible and deleting is not, which is what shapes this
/// screen: unarchive is a plain button on every row, while the delete actions
/// are red, ask first, and say exactly how many chats they will destroy.
class ArchivedChatsView extends ConsumerStatefulWidget {
  const ArchivedChatsView({super.key});

  @override
  ConsumerState<ArchivedChatsView> createState() => _ArchivedChatsViewState();
}

class _ArchivedChatsViewState extends ConsumerState<ArchivedChatsView> {
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  ArchivedQuery _query = const ArchivedQuery();

  @override
  void dispose() {
    _search.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setQuery(ArchivedQuery next) => setState(() => _query = next);

  /// Put a chat back in the sidebar. The toast is the only sign it worked —
  /// the row leaves this screen the moment it stops being archived.
  void _unarchive(Conversation chat) {
    ref.read(chatSessionsProvider.notifier).unarchiveConversation(chat.id);
    ToastScope.show(
      context,
      ToastSpec(
        message: '"${chat.title}" is back in your chats',
        action: ToastAction(
          label: 'Undo',
          onPressed: () => ref
              .read(chatSessionsProvider.notifier)
              .archiveConversation(chat.id),
        ),
      ),
    );
  }

  /// Open an archived chat to read it. It stays archived — reading is not
  /// restoring, and a chat that un-filed itself just because the user looked at
  /// it would make this screen impossible to review.
  void _open(Conversation chat) => openChat(ref, chat.id);

  Future<void> _delete(Conversation chat) async {
    final ok = await confirmDeleteChat(context, chat);
    if (!ok || !mounted) return;
    ref.read(chatSessionsProvider.notifier).deleteConversation(chat.id);
  }

  /// Delete a whole group, or the whole screen when [group] is null. Always
  /// scoped to *archived* chats — [deleteArchivedConversations] can't reach a
  /// live one even if an id slipped through.
  Future<void> _deleteMany({ArchivedGroup? group, required int count}) async {
    final ok = await _confirmDeleteMany(
      context,
      count: count,
      groupLabel: group?.label,
    );
    if (!ok || !mounted) return;
    ref
        .read(chatSessionsProvider.notifier)
        .deleteArchivedConversations(ids: group?.ids);
    if (!mounted) return;
    ToastScope.show(
      context,
      ToastSpec(message: count == 1 ? 'Chat deleted' : '$count chats deleted'),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette below — follow theme flips.
    AppTheme.watch(context);
    final sessions = ref.watch(chatSessionsProvider);
    final projects = ref.watch(sortedProjectsProvider);
    final archived = sessions.archived;
    final matches = filterArchived(archived, _query);
    final groups = groupArchivedByProject(matches, projects);

    return SectionScaffold(
      title: 'Archived chats',
      subtitle:
          'Chats you have put away. They stay out of your sidebar, '
          'search and menu bar until you bring them back.',
      // Nothing archived at all: the screen is the explanation, and nothing
      // else. Search and the filters are hidden rather than disabled — a
      // control that can only ever narrow an empty list to an empty list is an
      // invitation to a dead end, and hiding them lets the empty state have the
      // whole pane instead of hanging below a toolbar that does nothing.
      //
      // *Filtered* to empty is the opposite case (below): the controls have to
      // stay, or there's no way back to a list.
      child: archived.isEmpty
          ? const _NothingArchived()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Controls(
                  search: _search,
                  query: _query,
                  projects: projects,
                  onDeleteAll: () => _deleteMany(count: archived.length),
                  onChanged: _setQuery,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: matches.isEmpty
                      ? const EmptyState.noMatches(
                          message: 'No archived chat matches these filters.',
                          compact: false,
                        )
                      : _ArchivedList(
                          groups: groups,
                          scrollController: _scrollController,
                          onOpen: _open,
                          onUnarchive: _unarchive,
                          onDelete: _delete,
                          onDeleteGroup: (group) => _deleteMany(
                            group: group,
                            count: group.chats.length,
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

/// The row of controls above the list: search, scope, project, sort, and the
/// screen-level "Delete all".
class _Controls extends StatelessWidget {
  const _Controls({
    required this.search,
    required this.query,
    required this.projects,
    required this.onDeleteAll,
    required this.onChanged,
  });

  final TextEditingController search;
  final ArchivedQuery query;
  final List<Project> projects;

  /// Null greys the button out. The screen never passes null today — it hides
  /// this whole bar when nothing is archived — but the disabled state is kept
  /// so the bar stays correct if it's ever shown over an empty list.
  final VoidCallback? onDeleteAll;
  final ValueChanged<ArchivedQuery> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AppControl.heightField,
                child: TextField(
                  controller: search,
                  onChanged: (text) => onChanged(query.copyWith(text: text)),
                  style: const TextStyle(fontSize: 13),
                  decoration: labeledFieldDecoration('Search archived chats')
                      .copyWith(
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: kFieldIconSize,
                          color: AppPalette.textFaint,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 38,
                          minHeight: 36,
                        ),
                      ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _DeleteAllButton(onPressed: onDeleteAll),
          ],
        ),
        const SizedBox(height: 12),
        // Wrap so a narrow settings pane reflows the filters instead of
        // overflowing them.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FilterMenu<ArchivedScope>(
              icon: LucideIcons.listFilter300,
              value: query.scope,
              label: query.scope.label,
              options: [
                for (final scope in ArchivedScope.values)
                  (value: scope, label: scope.label),
              ],
              onSelected: (scope) => onChanged(
                query.copyWith(
                  scope: scope,
                  // A project pick only means something while projects are in
                  // scope; leaving it set behind "Outside projects" would show
                  // an empty list with no visible cause.
                  clearProjectId: scope == ArchivedScope.looseOnly,
                ),
              ),
            ),
            if (projects.isNotEmpty)
              _FilterMenu<String?>(
                icon: LucideIcons.folder300,
                value: query.projectId,
                label: _projectLabel(projects, query.projectId),
                options: [
                  (value: null, label: 'All projects'),
                  for (final p in projects) (value: p.id, label: p.name),
                ],
                onSelected: (id) => onChanged(
                  id == null
                      ? query.copyWith(clearProjectId: true)
                      : query.copyWith(
                          projectId: id,
                          // Picking a project implies you want project chats.
                          scope: query.scope == ArchivedScope.looseOnly
                              ? ArchivedScope.all
                              : query.scope,
                        ),
                ),
              ),
            _FilterMenu<ArchivedSort>(
              icon: LucideIcons.arrowUpDown300,
              value: query.sort,
              label: query.sort.label,
              options: [
                for (final sort in ArchivedSort.values)
                  (value: sort, label: sort.label),
              ],
              onSelected: (sort) => onChanged(query.copyWith(sort: sort)),
            ),
          ],
        ),
      ],
    );
  }

  static String _projectLabel(List<Project> projects, String? id) {
    if (id == null) return 'All projects';
    for (final p in projects) {
      if (p.id == id) return p.name;
    }
    // The project was removed while its filter was still on.
    return 'All projects';
  }
}

/// The screen-level destructive action. Red, and quiet until hovered, so it
/// reads as available without shouting over the list it can erase.
class _DeleteAllButton extends StatelessWidget {
  const _DeleteAllButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    final enabled = onPressed != null;
    return Tooltip(
      message: enabled
          ? 'Delete every archived chat'
          : 'Nothing archived to delete',
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: error,
          disabledForegroundColor: AppPalette.textFaint,
          backgroundColor: enabled
              ? error.withValues(alpha: 0.10)
              : Colors.transparent,
          minimumSize: const Size(0, AppControl.heightField),
          padding: AppControl.paddingSmall,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
        ),
        icon: const Icon(LucideIcons.trash2300, size: AppControl.iconSize),
        label: const Text('Delete all'),
      ),
    );
  }
}

/// A filter/sort control: a compact pill that opens the app's menu.
///
/// Hand-rolled rather than [AppSelectField] because these carry no label above
/// them — they're a toolbar of chips, not a form — and because the closed state
/// has to show the icon that says *which* filter it is.
class _FilterMenu<T> extends StatefulWidget {
  const _FilterMenu({
    required this.icon,
    required this.value,
    required this.label,
    required this.options,
    required this.onSelected,
  });

  final IconData icon;
  final T value;
  final String label;
  final List<({T value, String label})> options;
  final ValueChanged<T> onSelected;

  @override
  State<_FilterMenu<T>> createState() => _FilterMenuState<T>();
}

class _FilterMenuState<T> extends State<_FilterMenu<T>> {
  final _menu = MenuController();
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 5),
        ),
      ),
      menuChildren: [
        for (final option in widget.options)
          _FilterMenuRow(
            label: option.label,
            selected: option.value == widget.value,
            onTap: () {
              _menu.close();
              widget.onSelected(option.value);
            },
          ),
      ],
      builder: (context, controller, _) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            height: AppControl.heightField,
            padding: AppControl.paddingSmall,
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : AppPalette.cardBg,
              borderRadius: BorderRadius.circular(AppControl.radius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: AppControl.iconSize,
                  color: AppPalette.textSecondary,
                ),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: AppControl.fontSize,
                    fontWeight: AppControl.fontWeight,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevronDown300,
                  size: 14,
                  color: AppPalette.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in a filter menu — the standard menu row from the design system:
/// 6px gutter, radius 8, no ripple, selection marked by wash + weight + tick.
class _FilterMenuRow extends StatelessWidget {
  const _FilterMenuRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                // Fixed leading slot so labels line up whether or not they're
                // ticked.
                SizedBox(
                  width: 16,
                  child: selected
                      ? Icon(
                          LucideIcons.check300,
                          size: 14,
                          color: AppPalette.accentOnSurface,
                        )
                      : null,
                ),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: selected ? AppFont.medium : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The grouped list of archived chats, one section per project.
class _ArchivedList extends StatelessWidget {
  const _ArchivedList({
    required this.groups,
    required this.scrollController,
    required this.onOpen,
    required this.onUnarchive,
    required this.onDelete,
    required this.onDeleteGroup,
  });

  final List<ArchivedGroup> groups;
  final ScrollController scrollController;
  final ValueChanged<Conversation> onOpen;
  final ValueChanged<Conversation> onUnarchive;
  final ValueChanged<Conversation> onDelete;
  final ValueChanged<ArchivedGroup> onDeleteGroup;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: scrollController,
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.only(right: 12),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return Padding(
            padding: EdgeInsets.only(
              bottom: index == groups.length - 1 ? 0 : 24,
            ),
            child: _GroupSection(
              group: group,
              onOpen: onOpen,
              onUnarchive: onUnarchive,
              onDelete: onDelete,
              onDeleteGroup: () => onDeleteGroup(group),
            ),
          );
        },
      ),
    );
  }
}

/// One project's archived chats: a header naming it and counting them, with its
/// own "Delete all in project", then the rows.
class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.onOpen,
    required this.onUnarchive,
    required this.onDelete,
    required this.onDeleteGroup,
  });

  final ArchivedGroup group;
  final ValueChanged<Conversation> onOpen;
  final ValueChanged<Conversation> onUnarchive;
  final ValueChanged<Conversation> onDelete;
  final VoidCallback onDeleteGroup;

  @override
  Widget build(BuildContext context) {
    // Item of a lazy list — it must watch for itself, or it stays on the
    // palette it first built in when the theme flips.
    AppTheme.watch(context);
    final count = group.chats.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
          child: Row(
            children: [
              Icon(
                group.project == null
                    ? LucideIcons.messageSquare300
                    : LucideIcons.folder300,
                size: 15,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 8),
              // The name and its count read as one label, so they stay adjacent
              // and all the slack goes after them, pinning the "…" to the right
              // edge.
              //
              // The name is Flexible (it's the only part that may need to
              // ellipsis on a narrow pane) but the *cluster* must not be: a
              // Flexible cluster and the Spacer are both flex children with
              // flex 1, so they split the free space half and half and the
              // button lands mid-row. That was the bug — measured at x≈1004 of
              // a 1336-wide row, not at its edge.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        group.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 13.5,
                          fontWeight: AppFont.medium,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      count == 1 ? '1 chat' : '$count chats',
                      style: TextStyle(
                        color: AppPalette.textFaint,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              // The only flex child left, so it takes *all* the slack.
              const Spacer(),
              _GroupMenuButton(
                label: group.project == null
                    ? 'Delete all outside projects'
                    : 'Delete all in project',
                onDeleteGroup: onDeleteGroup,
              ),
            ],
          ),
        ),
        for (final chat in group.chats)
          _ArchivedRow(
            chat: chat,
            onOpen: () => onOpen(chat),
            onUnarchive: () => onUnarchive(chat),
            onDelete: () => onDelete(chat),
          ),
      ],
    );
  }
}

/// The "…" on a group header. One entry today, but it's the right shape for the
/// group-level actions that follow, and it keeps a destructive action out of
/// single-click reach.
class _GroupMenuButton extends StatefulWidget {
  const _GroupMenuButton({required this.label, required this.onDeleteGroup});

  final String label;
  final VoidCallback onDeleteGroup;

  @override
  State<_GroupMenuButton> createState() => _GroupMenuButtonState();
}

class _GroupMenuButtonState extends State<_GroupMenuButton> {
  final _menu = MenuController();
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 5),
        ),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: () {
                _menu.close();
                widget.onDeleteGroup();
              },
              borderRadius: BorderRadius.circular(8),
              hoverColor: error.withValues(alpha: 0.09),
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.trash2300, size: 15, color: error),
                    const SizedBox(width: 9),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: error,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        label: 'Group options',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: AnimatedContainer(
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              width: 26,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              ),
              child: Icon(
                LucideIcons.ellipsis300,
                size: 16,
                color: _hovered
                    ? AppPalette.textPrimary
                    : AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One archived chat: its title, when it was archived, and the two ways out.
///
/// The whole row opens the chat; Unarchive and Delete are their own targets,
/// and both stop the tap from reaching the row underneath.
class _ArchivedRow extends StatefulWidget {
  const _ArchivedRow({
    required this.chat,
    required this.onOpen,
    required this.onUnarchive,
    required this.onDelete,
  });

  final Conversation chat;
  final VoidCallback onOpen;
  final VoidCallback onUnarchive;
  final VoidCallback onDelete;

  @override
  State<_ArchivedRow> createState() => _ArchivedRowState();
}

class _ArchivedRowState extends State<_ArchivedRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Built inside a lazy list — watch here, not just in the parent.
    AppTheme.watch(context);
    final chat = widget.chat;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: BoxDecoration(
              // A raised block, so it reads as a card on the settings page —
              // fill alone is ~1.05:1 against the page and would be invisible
              // without the shadow.
              color: AppGlass.surfaceFill,
              borderRadius: BorderRadius.circular(14),
              boxShadow: AppGlass.cardShadow,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 13.5,
                          fontWeight: AppFont.medium,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _archivedLabel(chat),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textFaint,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // The actions stay mounted rather than appearing on hover: this
                // is a management screen, and a row whose controls are hidden
                // until pointed at is a row a keyboard user can't discover.
                AnimatedOpacity(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  opacity: _hovered ? 1 : 0.82,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RowAction(
                        icon: LucideIcons.trash2300,
                        tooltip: 'Delete permanently',
                        danger: true,
                        onPressed: widget.onDelete,
                      ),
                      const SizedBox(width: 4),
                      _UnarchiveButton(onPressed: widget.onUnarchive),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Unarchive" — the row's primary action, and the reason the screen exists.
class _UnarchiveButton extends StatelessWidget {
  const _UnarchiveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: 'Put this chat back in your sidebar',
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppPalette.textPrimary,
          backgroundColor: AppCard.inset,
          minimumSize: const Size(0, AppControl.heightSmall),
          padding: AppControl.paddingSmall,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
        ),
        child: const Text('Unarchive'),
      ),
    );
  }
}

/// A quiet icon button on a row.
class _RowAction extends StatefulWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool danger;

  @override
  State<_RowAction> createState() => _RowActionState();
}

class _RowActionState extends State<_RowAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    final tint = widget.danger ? error : AppPalette.textSecondary;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            width: 28,
            height: AppControl.heightSmall,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppControl.radius),
              color: _hovered
                  ? (widget.danger
                        ? error.withValues(alpha: 0.10)
                        : AppSurface.hoverFill)
                  : Colors.transparent,
            ),
            child: Icon(widget.icon, size: AppControl.iconSize, color: tint),
          ),
        ),
      ),
    );
  }
}

/// Nothing has ever been archived — not a failed search, so it explains what
/// the screen is for instead of offering a filter to clear.
class _NothingArchived extends StatelessWidget {
  const _NothingArchived();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.archive_outlined,
      title: 'No archived chats',
      message:
          'Archive a chat from its "…" menu to file it away here. '
          'Nothing is deleted, and you can bring it back any time.',
    );
  }
}

/// When [chat] was archived, in words — "Archived today", "Archived 3 days ago".
String _archivedLabel(Conversation chat) {
  final at = chat.archivedAt;
  if (at == null) return '';
  final now = DateTime.now();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  return switch (days) {
    <= 0 => 'Archived today',
    1 => 'Archived yesterday',
    < 7 => 'Archived $days days ago',
    < 30 => 'Archived ${days ~/ 7} ${days ~/ 7 == 1 ? 'week' : 'weeks'} ago',
    _ => 'Archived on ${at.day}/${at.month}/${at.year}',
  };
}

/// Asks before a bulk delete, naming the count — the number is the whole point,
/// since this is the one action here that can destroy many chats at once.
Future<bool> _confirmDeleteMany(
  BuildContext context, {
  required int count,
  String? groupLabel,
}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      AppTheme.watch(context);
      final theme = Theme.of(context);
      final what = count == 1 ? '1 archived chat' : '$count archived chats';
      return AlertDialog(
        // Lifted off the window, like the app's other dialogs — see
        // confirmDeleteChat.
        backgroundColor: appMenuFill(),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppGlass.hair),
        ),
        titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
        contentPadding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
        actionsPadding: const EdgeInsets.fromLTRB(28, 16, 22, 22),
        title: Text(
          count == 1
              ? 'Delete archived chat?'
              : 'Delete $count archived chats?',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            groupLabel == null
                ? '$what and every message in them will be deleted. '
                      'Your other chats are not affected. This cannot be undone.'
                : '$what in "$groupLabel" and every message in them will be '
                      'deleted. This cannot be undone.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
              height: 1.45,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
