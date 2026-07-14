import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../../../shared/theme/app_theme.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/add_project.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

/// The sidebar's body: your projects, each holding the chats you opened inside
/// it, then the chats that belong to no project.
///
/// A chat lives *in* a folder — that's what lets the assistant read your files
/// while it answers — so the history is grouped by project rather than by the
/// day it happened, which told you nothing about what it was for.
///
/// [query] filters chat titles as the sidebar's search box types into it.
class ChatHistoryList extends ConsumerWidget {
  const ChatHistoryList({super.key, this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(chatSessionsProvider);
    final projects = ref.watch(projectsProvider);
    final matches = _filter(sessions.conversations, query);

    final loose = [
      for (final c in matches)
        if (c.projectId == null || !projects.any((p) => p.id == c.projectId)) c,
    ];

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _ProjectsHeader(
          onAdd: () => addProjectFromPicker(ref),
          onManage: () =>
              ref.read(shellSectionProvider.notifier).select(
                ShellSection.projects,
              ),
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
              searching: query.trim().isNotEmpty,
            ),
        const SidebarSectionLabel(label: 'Chats'),
        if (loose.isEmpty)
          const _Hint(text: 'Chats outside a project show up here.')
        else
          for (final chat in loose) _ChatRow(chat: chat),
      ],
    );
  }

  List<Conversation> _filter(List<Conversation> all, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final c in all)
        if (c.title.toLowerCase().contains(q)) c,
    ];
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 2, 2),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: 'Manage projects',
              child: InkWell(
                onTap: onManage,
                child: const Padding(
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
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            padding: EdgeInsets.zero,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.add_rounded),
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
  const _ProjectGroup({
    required this.project,
    required this.chats,
    required this.searching,
  });

  final Project project;
  final List<Conversation> chats;

  /// While the user is searching, groups stay open — a match hidden inside a
  /// collapsed folder would look like no match at all.
  final bool searching;

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
    final open = _open || widget.searching;
    final missing = !widget.project.exists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarItem(
          icon: missing
              ? Icons.folder_off_outlined
              : (open ? Icons.folder_open_rounded : Icons.folder_rounded),
          label: widget.project.name,
          tooltip: missing
              ? "This folder isn't there any more: ${widget.project.path}"
              : widget.project.path,
          onTap: () => setState(() => _open = !_open),
          trailing: IconButton(
            tooltip: 'New chat in ${widget.project.name}',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            iconSize: 15,
            splashRadius: 14,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.add_rounded),
            onPressed: _newChatHere,
          ),
        ),
        if (open) ...[
          if (widget.chats.isEmpty)
            const _Hint(text: 'No chats yet', indented: true)
          else
            for (final chat in widget.chats) _ChatRow(chat: chat, indented: true),
        ],
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
    final controller = ref.read(chatSessionsProvider.notifier);
    final selected = ref.watch(chatSessionsProvider).activeId == chat.id;

    return Padding(
      padding: EdgeInsets.only(left: indented ? 16 : 0),
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
          iconSize: 15,
          splashRadius: 14,
          color: AppPalette.textSecondary,
          icon: const Icon(Icons.delete_outline_rounded),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Add a folder and chat about the files in it.',
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => addProjectFromPicker(ref),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('Add a project'),
          ),
        ],
      ),
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
    return Padding(
      padding: EdgeInsets.fromLTRB(indented ? 26 : 10, 4, 10, 6),
      child: Text(
        text,
        style: const TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
