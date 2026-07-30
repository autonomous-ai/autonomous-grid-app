import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../../agent/logic/agent_providers.dart';
import '../../projects/logic/project.dart';
import '../logic/active_workdir.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'workspace_files_dialog.dart';

const _menuWidth = 208.0;
const _rowHeight = 34.0;
const _dividerHeight = 9.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: the two drifting apart is what pushes the
/// menu off its button.
const _menuPadding = 5.0;

/// Each row's 1px breathing room above and below, which the gutter recipe adds
/// outside [_rowHeight].
const _rowGap = 1.0;

/// What the menu will measure. Summed rather than guessed so
/// [anchoredMenuPosition] lands the menu on the button instead of near it.
/// Three rows above the divider now (rename, archive, copy), one below.
const _menuSize = Size(
  _menuWidth,
  _menuPadding * 2 + (_rowHeight + _rowGap * 2) * 4 + _dividerHeight,
);

/// Names the conversation you're reading: a mark, the title, and the "…" that
/// acts on it.
///
/// Rides in the left of [AppTopBar] rather than in a strip of its own, so the
/// chat's identity and the grid's summary read as one row instead of two
/// stacked bars a few pixels out of line with each other. The chat view keeps
/// ownership of *whether* it shows — that depends on `noModel`/`isNewChat`,
/// which only it can compute — and publishes itself through
/// [chatHeaderVisibleProvider].
///
/// Absent until a conversation exists. A fresh chat is all starters, and a
/// header naming one would name a thing the user hasn't made yet.
class ChatHeader extends ConsumerWidget {
  const ChatHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The strip tints from a global the element tree can't track, so subscribe
    // to the brightness directly.
    AppTheme.watch(context);
    // The open conversation alone: watching the whole state rebuilt the header
    // on every streamed token, and a token doesn't change the chat it lands in.
    final active = ref.watch(chatSessionsProvider.select((s) => s.active));
    if (active == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.messageSquare300,
          size: 16,
          color: AppPalette.textSecondary,
        ),
        const SizedBox(width: 9),
        // Bounded, not Expanded: the title should sit beside its "…" like a
        // label on a tab, not stretch the menu button out to the far edge of
        // a wide window.
        Flexible(
          child: Text(
            active.title,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13.5,
              fontWeight: AppFont.medium,
            ),
          ),
        ),
        const SizedBox(width: 4),
        const _ChatFilesButton(),
        const SizedBox(width: 2),
        ChatHeaderMenuButton(conversation: active),
      ],
    );
  }
}

/// Opens the browser for the folder this chat runs in — where the assistant
/// reads and saves files.
///
/// The point of it is the loose chat: with no project, the assistant's files
/// land in an app folder the user would never think to look in, and the reply's
/// bare path is no way to reach them. This is the standing door to that folder
/// (the "changed files" bar over the composer is a passing notice that hides
/// itself); in a project it browses the project folder instead.
class _ChatFilesButton extends ConsumerWidget {
  const _ChatFilesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workdir = ref.watch(activeChatWorkdirProvider);
    final isWorkspace = workdir == ref.watch(agentWorkspaceDirProvider).path;
    final project = ref.watch(
      projectByIdProvider(
        ref.watch(chatSessionsProvider.select((s) => s.openProjectId)),
      ),
    );
    // "Workspace" for a loose chat's app folder; the project's name when the
    // chat belongs to one — the label the breadcrumb roots itself under.
    final rootLabel = isWorkspace
        ? 'Workspace'
        : (project?.name ?? _basename(workdir));
    return _HeaderHoverButton(
      icon: LucideIcons.folder300,
      tooltip: 'Files in this chat’s folder',
      semanticsLabel: 'Chat files',
      onTap: () => showWorkspaceFilesDialog(
        context,
        rootPath: workdir,
        rootLabel: rootLabel,
      ),
    );
  }

  static String _basename(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final cut = trimmed.lastIndexOf('/');
    return cut < 0 ? trimmed : trimmed.substring(cut + 1);
  }
}

/// Whether the chat view currently wants its header in the top bar.
///
/// The two conditions that gate it (a model is reachable, and the chat isn't
/// still on its starters screen) are only computable inside the chat view, so
/// it writes the answer here rather than the shell re-deriving it.
final chatHeaderVisibleProvider =
    NotifierProvider<ChatHeaderVisibleNotifier, bool>(
      ChatHeaderVisibleNotifier.new,
    );

class ChatHeaderVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool visible) => state = visible;
}

/// The "…" on the header: rename this chat, copy it out, or delete it.
class ChatHeaderMenuButton extends ConsumerStatefulWidget {
  const ChatHeaderMenuButton({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ChatHeaderMenuButton> createState() =>
      _ChatHeaderMenuButtonState();
}

class _ChatHeaderMenuButtonState extends ConsumerState<ChatHeaderMenuButton> {
  final _menu = MenuController();

  Conversation get _chat => widget.conversation;

  Future<void> _rename() async {
    _menu.close();
    final title = await showRenameChatDialog(context, _chat);
    if (title == null) return;
    ref.read(chatSessionsProvider.notifier).renameConversation(_chat.id, title);
  }

  Future<void> _copy() async {
    _menu.close();
    await Clipboard.setData(ClipboardData(text: transcriptText(_chat)));
    if (!mounted) return;
    ToastScope.show(context, const ToastSpec(message: 'Transcript copied'));
  }

  /// Archive without asking: nothing is destroyed, and the toast carries the
  /// way back. A confirm dialog for a reversible action trains the user to
  /// dismiss dialogs, which is what makes the *delete* one stop working.
  void _archive() {
    _menu.close();
    final id = _chat.id;
    ref.read(chatSessionsProvider.notifier).archiveConversation(id);
    ToastScope.show(
      context,
      ToastSpec(
        message: 'Chat archived',
        action: ToastAction(
          label: 'Undo',
          onPressed: () =>
              ref.read(chatSessionsProvider.notifier).unarchiveConversation(id),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    _menu.close();
    final ok = await confirmDeleteChat(context, _chat);
    if (!ok) return;
    ref.read(chatSessionsProvider.notifier).deleteConversation(_chat.id);
  }

  void _toggle(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    // Right-aligned: the button sits at the title's trailing edge, so a menu
    // growing rightwards from it would hang over the transcript.
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize,
        margin: 8,
        gap: 6,
        alignEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      // The shared surface, not a hand-rolled one: it lifts the fill clear of
      // *both* grounds a menu can open over. The header sits on the window, but
      // the themed default lands within 1.02:1 of a raised block and in light
      // both are white — a panel with no edge at all.
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuPadding),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      menuChildren: [
        _ChatMenuContent(
          onRename: _rename,
          onArchive: _archive,
          onCopy: _copy,
          onDelete: _delete,
        ),
      ],
      builder: (context, controller, _) => _HeaderHoverButton(
        icon: LucideIcons.ellipsis300,
        tooltip: 'Chat options',
        semanticsLabel: 'Chat options',
        onTap: () => _toggle(context, controller),
      ),
    );
  }
}

/// A quiet 24px square icon target that warms and fills under the pointer — the
/// header's hover treatment, shared by the files button and the "…" menu so they
/// read as one family of controls instead of two hand-styled buttons.
class _HeaderHoverButton extends StatefulWidget {
  const _HeaderHoverButton({
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  State<_HeaderHoverButton> createState() => _HeaderHoverButtonState();
}

class _HeaderHoverButtonState extends State<_HeaderHoverButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 17,
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

/// The menu's rows. Lives in the MenuAnchor's overlay — detached from the
/// header, so it depends on the brightness directly rather than inheriting it.
class _ChatMenuContent extends StatelessWidget {
  const _ChatMenuContent({
    required this.onRename,
    required this.onArchive,
    required this.onCopy,
    required this.onDelete,
  });

  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChatMenuItem(
            icon: LucideIcons.pencilLine300,
            label: 'Rename chat',
            onPressed: onRename,
          ),
          _ChatMenuItem(
            icon: LucideIcons.archive300,
            label: 'Archive chat',
            onPressed: onArchive,
          ),
          _ChatMenuItem(
            icon: LucideIcons.copy300,
            label: 'Copy transcript',
            onPressed: onCopy,
          ),
          // The one destructive entry, fenced off so it can't be hit on the way
          // to Copy.
          const _ChatMenuDivider(),
          _ChatMenuItem(
            icon: LucideIcons.trash2300,
            label: 'Delete chat',
            onPressed: onDelete,
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// One menu row, hand-rolled per the design system's §5 recipe: the app has no
/// `menuButtonTheme`, so a bare `MenuItemButton` would take Material's defaults
/// (square corners, 14pt label, a grey `onSurface` hover, an ink ripple).
class _ChatMenuItem extends StatefulWidget {
  const _ChatMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Tints the row red and gives it a red hover wash — for [_delete] alone.
  final bool danger;

  @override
  State<_ChatMenuItem> createState() => _ChatMenuItemState();
}

class _ChatMenuItemState extends State<_ChatMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Lives in the MenuAnchor's overlay, detached from the header's subtree —
    // so it watches the palette itself.
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    // The glyph rests a step below the label and comes up to meet it under the
    // pointer — the same "fills in on hover" move the rail's actions make, so a
    // hovered row reads as one lit object instead of a lit label beside a grey
    // icon. Danger keeps its red throughout: dimming it would file the one
    // destructive row in with the rest.
    final tint = widget.danger
        ? error
        : _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

    return Padding(
      // The 6px gutter is what makes the hover highlight read as an inset pill
      // rather than a full-bleed band across the panel.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: _rowGap),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(8),
          hoverColor: widget.danger
              ? error.withValues(alpha: 0.09)
              : AppSurface.hoverFill,
          // The app's menus have no ink ripple; MenuItemButton brought one.
          splashFactory: NoSplash.splashFactory,
          onHover: (value) => setState(() => _hovered = value),
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(
                children: [
                  // Fixed 16px leading slot so labels line up whatever the
                  // glyph's own width.
                  SizedBox(
                    width: 16,
                    child: Icon(widget.icon, size: 16, color: tint),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.danger ? error : AppPalette.textPrimary,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatMenuDivider extends StatelessWidget {
  const _ChatMenuDivider();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: _dividerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, thickness: 1, color: AppPalette.divider),
      ),
    );
  }
}

/// The conversation as plain text, for the clipboard — one labelled block per
/// turn, in the order they were said.
String transcriptText(Conversation chat) => [
  for (final m in chat.messages)
    '${m.role == ChatRole.user ? 'You' : 'Assistant'}: ${m.text}',
].join('\n\n');

/// Renames [chat] after asking for the new name. Returns the new title, or null
/// if the user cancelled or left it blank.
Future<String?> showRenameChatDialog(
  BuildContext context,
  Conversation chat,
) async {
  final controller = TextEditingController(text: chat.title);
  try {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameChatDialog(controller: controller),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  } finally {
    // After the frame, not the moment `showDialog` returns: the dialog is still
    // animating out and rebuilds its TextField on the way, which would read a
    // controller disposed out from under it.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}

/// The rename form: one labelled field in the app's dialog frame.
///
/// Stateful only to keep Rename disabled while the field is empty — a rename to
/// nothing is the one input this form can't act on, so it says so by going grey
/// rather than by accepting the click and silently doing nothing.
class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({required this.controller});

  final TextEditingController controller;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  bool get _canRename => widget.controller.text.trim().isNotEmpty;

  void _submit() {
    if (!_canRename) return;
    Navigator.pop(context, widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      // Not windowBg: the dialog opens *over* the window, which is windowBg too
      // — 1.00:1 against its own ground in both themes, an edgeless slab. This
      // is the same fill the menus use, lifted clear of the page (1.38:1 in
      // dark), and it keeps the field inside readable: cardBg on cardBg would
      // be another 1.00:1, trading this bug for the field vanishing instead.
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        // In light the fill is white like the page beneath it, so the rim is the
        // only thing drawing the dialog's edge.
        side: BorderSide(color: AppGlass.hair),
      ),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Text(
        'Rename chat',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      // Narrower than the skill form's 540: one short line of text doesn't need
      // that much run, and a wide box around a small field reads as unfinished.
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            LabeledField(
              label: 'Name',
              controller: widget.controller,
              hint: 'What this chat is about',
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canRename ? _submit : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Asks before dropping [chat]. Deleting throws the transcript away for good, so
/// it asks rather than offering an undo it can't honour.
Future<bool> confirmDeleteChat(BuildContext context, Conversation chat) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      AppTheme.watch(context);
      final theme = Theme.of(context);
      return AlertDialog(
        // Lifted off the window for the same reason as the rename dialog — see
        // there.
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
          'Delete chat?',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            '"${chat.title}" and every message in it will be deleted. '
            'This cannot be undone.',
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
          // Red fill, not the accent: this is the one button here that destroys
          // something, and it shouldn't wear the same colour as Rename.
          //
          // Background only, matching the app's other destructive buttons
          // (skill_list, mcp_list, network_detail) — the scheme picks the label
          // colour, so if the dark error red is ever retuned for contrast, this
          // follows instead of holding a stale hard-coded pair.
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
