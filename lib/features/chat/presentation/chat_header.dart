import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

const _menuWidth = 208.0;
const _rowHeight = 34.0;
const _dividerHeight = 9.0;
const _menuPadding = 6.0;

/// What the menu will measure. Summed rather than guessed so
/// [anchoredMenuPosition] lands the menu on the button instead of near it.
const _menuSize = Size(
  _menuWidth,
  _menuPadding * 2 + _rowHeight * 2 + _dividerHeight + _rowHeight,
);

/// The strip above the transcript naming the conversation you're reading: a
/// mark, the title, and the "…" that acts on it — closed off by a hairline so
/// the turns below start against an edge rather than floating under the window
/// chrome.
///
/// Absent until a conversation exists. A fresh chat is all starters, and a
/// header over it would name a thing the user hasn't made yet.
class ChatHeader extends ConsumerWidget {
  const ChatHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The strip tints from a global the element tree can't track, so subscribe
    // to the brightness directly.
    AppTheme.watch(context);
    final active = ref.watch(chatSessionsProvider).active;
    if (active == null) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppPalette.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
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
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            ChatHeaderMenuButton(conversation: active),
          ],
        ),
      ),
    );
  }
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
          onCopy: _copy,
          onDelete: _delete,
        ),
      ],
      builder: (context, controller, _) =>
          _MenuTrigger(onTap: () => _toggle(context, controller)),
    );
  }
}

/// The "…" itself: a quiet target that warms and fills under the pointer, so it
/// says "click me" the way the project and account menus do.
class _MenuTrigger extends StatefulWidget {
  const _MenuTrigger({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_MenuTrigger> createState() => _MenuTriggerState();
}

class _MenuTriggerState extends State<_MenuTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Semantics(
      button: true,
      label: 'Chat options',
      child: Tooltip(
        message: 'Chat options',
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
                LucideIcons.ellipsis300,
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
    required this.onCopy,
    required this.onDelete,
  });

  final VoidCallback onRename;
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

class _ChatMenuItem extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final tint = danger ? error : AppPalette.textSecondary;
    return MenuItemButton(
      onPressed: onPressed,
      requestFocusOnHover: false,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        overlayColor: WidgetStatePropertyAll(
          danger ? error.withValues(alpha: 0.09) : AppSurface.hoverFill,
        ),
        // Pinned, not a minimum: the menu is positioned by summing these
        // heights, and Flutter defaults visualDensity to *compact* on desktop —
        // which would take 8px off every row and float the menu clear of the
        // button.
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, _rowHeight)),
        maximumSize: const WidgetStatePropertyAll(
          Size(double.infinity, _rowHeight),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: danger ? error : AppPalette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
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
