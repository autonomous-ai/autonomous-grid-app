import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../../../shared/theme/app_theme.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/add_project.dart';
import '../../projects/presentation/project_menu.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

/// The sidebar's body: your projects, each holding the chats you opened inside
/// it, then the chats that belong to no project.
///
/// A chat lives *in* a folder — that's what lets the assistant read your files
/// while it answers — so the history is grouped by project rather than by the
/// day it happened, which told you nothing about what it was for.
///
/// Searching isn't here: it's in the palette (⌘K), which finds projects and
/// scheduled tasks too.
class ChatHistoryList extends ConsumerStatefulWidget {
  const ChatHistoryList({super.key});

  @override
  ConsumerState<ChatHistoryList> createState() => _ChatHistoryListState();
}

class _ChatHistoryListState extends ConsumerState<ChatHistoryList> {
  // The list and its scrollbar have to share one controller, or the desktop
  // scroll behaviour mounts a *second*, uncontrolled bar over the top.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(chatSessionsProvider);
    final projects = ref.watch(sortedProjectsProvider);
    final matches = sessions.conversations;

    final loose = [
      for (final c in matches)
        if (c.projectId == null || !projects.any((p) => p.id == c.projectId)) c,
    ];

    // The scrollbar rides in a 6px gutter at the rail's edge; the rows are
    // inset a matching amount on the right (10 base + 6 gutter) so their content
    // — and the "+" button — never runs under the thumb. Codex keeps exactly
    // this clear gap between the list and its scrollbar.
    return Scrollbar(
      controller: _scrollController,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.only(left: 10, right: 16),
        children: [
          _ProjectsHeader(
            onAdd: () => addProjectFromPicker(ref),
            onManage: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.projects),
          ),
          if (projects.isEmpty)
            const _AddFirstProjectHint()
          else
            for (final project in projects)
              _ProjectGroup(
                project: project,
                chats: [
                  for (final c in matches)
                    if (c.projectId == project.id) c,
                ],
              ),
          const SidebarSectionLabel(label: 'Chats'),
          if (loose.isEmpty)
            const _Hint(
              text: 'Chats outside a project show up here.',
              indented: true,
            )
          else
            // Indented like a project's chats so every conversation's title sits
            // in the same column, whether or not it belongs to a project — the
            // "Chats" and "Projects" labels stay at the outer edge, their contents
            // line up one step in.
            for (final chat in loose) _ChatRow(chat: chat, indented: true),
        ],
      ),
    );
  }
}

/// "Projects" — the label opens the screen that manages them, the button adds
/// one straight from here.
class _ProjectsHeader extends StatelessWidget {
  const _ProjectsHeader({required this.onAdd, required this.onManage});

  final VoidCallback onAdd;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 2, 2),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: 'Manage projects',
              child: InkWell(
                onTap: onManage,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Projects',
                    style: TextStyle(
                      color: AppPalette.textFaint,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add a folder as a project',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            padding: EdgeInsets.zero,
            color: AppPalette.textSecondary,
            icon: const Icon(LucideIcons.plus300),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

/// One project and the chats inside it. Collapsible, because a folder you're not
/// working in today shouldn't cost you half the rail.
class _ProjectGroup extends ConsumerStatefulWidget {
  const _ProjectGroup({required this.project, required this.chats});

  final Project project;
  final List<Conversation> chats;

  @override
  ConsumerState<_ProjectGroup> createState() => _ProjectGroupState();
}

class _ProjectGroupState extends ConsumerState<_ProjectGroup> {
  bool _open = true;

  void _newChatHere() {
    ref
        .read(chatSessionsProvider.notifier)
        .newChat(projectId: widget.project.id);
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette.textSecondary — follow theme flips.
    AppTheme.watch(context);
    final open = _open;
    final missing = !widget.project.exists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarItem(
          // Lucide's outline folders — thinner and rounder than Material's, and
          // the shape the design mocks use: closed while collapsed, open once
          // expanded (folderX for a folder that's gone missing) so the icon
          // itself tells you the group's state.
          icon: missing
              ? LucideIcons.folderX300
              : (open ? LucideIcons.folderOpen300 : LucideIcons.folder300),
          label: widget.project.name,
          tooltip: missing
              ? "This folder isn't there any more: ${widget.project.path}"
              : widget.project.path,
          onTap: () => setState(() => _open = !_open),
          // Two actions here (options menu + new chat), so reserve room for both.
          trailingWidth: 48,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProjectMenuButton(project: widget.project),
              IconButton(
                tooltip: 'New chat in ${widget.project.name}',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                iconSize: 17,
                splashRadius: 14,
                color: AppPalette.textSecondary,
                icon: const Icon(LucideIcons.plus300),
                onPressed: _newChatHere,
              ),
            ],
          ),
        ),
        // Expanding/collapsing animates the group's height so the rows below
        // glide instead of jumping; each chat inside then fades in and drifts up
        // into place, staggered a hair so they arrive as a wave rather than all
        // at once. Collapsing just shrinks the height (the rows leave with it).
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.chats.isEmpty)
                      const _RevealItem(
                        index: 0,
                        child: _Hint(text: 'No chats yet', indented: true),
                      )
                    else
                      for (var i = 0; i < widget.chats.length; i++)
                        _RevealItem(
                          index: i,
                          child: _ChatRow(
                            chat: widget.chats[i],
                            indented: true,
                          ),
                        ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// One chat. Selecting it opens it — and puts you back in Chat if you'd wandered
/// off to another screen, so a click never silently changes something behind the
/// page you're looking at.
class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat, this.indented = false});

  final Conversation chat;
  final bool indented;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reads AppPalette.textFaint — follow theme flips.
    AppTheme.watch(context);
    final controller = ref.read(chatSessionsProvider.notifier);
    // Highlighted only while you're actually *in* the chat: on Plugins or
    // Scheduled the open screen is the one to mark, and two lit rows in one rail
    // would leave you guessing which page you're looking at. The chat stays the
    // one you come back to — it just doesn't claim to be on screen.
    final selected =
        ref.watch(chatSessionsProvider).activeId == chat.id &&
        ref.watch(shellSectionProvider) == ShellSection.chat;

    return Padding(
      // Line a project's chats up under the project *name*, not under its
      // folder icon: the row's own 10px inset + an 18px icon + a 10px gap put the
      // name's text at 38px, so a 28px indent here lands the chat's text in the
      // same column. Codex keeps this one clean left edge; anything else makes
      // the list read as ragged.
      padding: EdgeInsets.only(left: indented ? 28 : 0),
      child: SidebarItem(
        label: chat.title,
        selected: selected,
        onTap: () {
          controller.select(chat.id);
          ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
        },
        trailing: IconButton(
          tooltip: 'Delete chat',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          iconSize: 16,
          splashRadius: 14,
          color: AppPalette.textFaint,
          icon: const Icon(LucideIcons.trash2300),
          onPressed: () => controller.deleteConversation(chat.id),
        ),
      ),
    );
  }
}

/// The nudge that replaces an empty Projects list — the app's whole point is
/// asking about your own files, so a blank rail would waste the moment.
class _AddFirstProjectHint extends ConsumerWidget {
  const _AddFirstProjectHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reads AppPalette.textFaint — follow theme flips.
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add a folder and chat about the files in it.',
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => addProjectFromPicker(ref),
            // Compact: this sits inline under the project list, not as a
            // standalone action.
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppControl.heightSmall),
              padding: AppControl.paddingSmall,
            ),
            icon: const Icon(
              LucideIcons.folderPlus300,
              size: AppControl.iconSize,
            ),
            label: const Text('Add a project'),
          ),
        ],
      ),
    );
  }
}

/// Fades a freshly-revealed row in while drifting it up into place. Mounted only
/// when a project expands, so its one-shot entry animation plays each time the
/// group opens; the [index] staggers the start so a list of chats arrives as a
/// gentle wave rather than all together.
///
/// It's entry-only — collapsing is handled by the parent's [AnimatedSize]
/// shrinking the group's height, which carries these rows out with it.
class _RevealItem extends StatefulWidget {
  const _RevealItem({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<_RevealItem> {
  @override
  Widget build(BuildContext context) {
    // A total window a touch longer than one row's animation, so staggering the
    // start by index still lands every row inside it. Capped so a long list
    // never feels slow — past the eighth row there's no extra delay.
    const step = 0.12;
    final begin = (widget.index.clamp(0, 8) * step).toDouble();
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.index),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 460),
      curve: Interval(begin, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          // Start ~8px low and rise to rest — the "up" in fade-in-up.
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// A quiet line where a list would otherwise be empty.
class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.indented = false});

  final String text;
  final bool indented;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette.textFaint — follow theme flips.
    AppTheme.watch(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(indented ? 28 : 10, 4, 10, 6),
      child: Text(
        text,
        style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
