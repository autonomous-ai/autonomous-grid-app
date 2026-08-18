import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/reveal_chat.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/layouts/widgets/rail_section_header.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../../../shared/layouts/widgets/sidebar_show_more.dart';
import '../../../shared/layouts/widgets/sidebar_timeline.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../../shared/widgets/toast.dart';
import '../../projects/logic/project.dart';
import '../../projects/logic/project_folder_status.dart';
import '../../projects/presentation/create_project_dialog.dart';
import '../../projects/presentation/project_menu.dart';
import '../../scheduled/logic/task_conversation_id.dart';
import '../../scheduled/logic/task_unread_store.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'chat_hover_preview.dart';

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

/// The rail's own inset. The scrollbar rides in a 6px gutter at its edge, so the
/// rows are inset a matching amount on the right (10 base + 6 gutter) and their
/// content — and the "+" button — never runs under the thumb. Codex keeps exactly
/// this clear gap between the list and its scrollbar.
const _railPadding = EdgeInsets.only(left: 10, right: 16);

class _ChatHistoryListState extends ConsumerState<ChatHistoryList> {
  // The list and its scrollbar have to share one controller, or the desktop
  // scroll behaviour mounts a *second*, uncontrolled bar over the top.
  final _scrollController = ScrollController();

  // How many pages of each section the user has opened. Held here rather than
  // in the sections themselves so the rail is one scrollable thing again after
  // a click, and so both counts survive the rebuild every streamed token causes
  // upstream. They only ever grow: having asked to see more chats, you don't
  // expect the list to fold back up because one of them finished replying.
  int _projectPages = 1;
  int _loosePages = 1;

  // Whether the loose-chat section is unfolded. A project row folds the chats
  // under it, so the one group in the rail that *couldn't* fold read as an
  // oversight — and it's the group most likely to be hundreds of rows long.
  bool _chatsOpen = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The conversation list itself, not the whole state: the rail's contents
    // depend on nothing else, and watching the state rebuilt every row on each
    // streamed token and each chat switch. The field is only ever replaced, so
    // its identity is the change signal.
    final conversations = ref.watch(
      chatSessionsProvider.select((s) => s.conversations),
    );
    // The saved chats are read off the first frame, so an empty list is two
    // different facts — nothing saved, or nothing read *yet*. Only the first of
    // them may be told to the user.
    final loading = ref.watch(chatSessionsProvider.select((s) => s.loading));
    final projects = ref.watch(sortedProjectsProvider);
    // Live only: an archived chat is hidden from the rail until the user brings
    // it back from Settings › Archived.
    final matches = liveConversations(conversations);

    final loose = [
      for (final c in matches)
        if (c.projectId == null || !projects.any((p) => p.id == c.projectId)) c,
    ];

    // A long rail is a rail you scroll instead of read, so each section opens
    // with one page and hands the rest to a "Show more" row. Both counts are
    // clamped to their list, so the row is built only while something is
    // genuinely hidden — the last page never leaves a button behind that reveals
    // nothing.
    final shownProjects = sidebarPageCount(_projectPages, projects.length);
    final shownLoose = sidebarPageCount(_loosePages, loose.length);

    return Scrollbar(
      controller: _scrollController,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverPadding(
            padding: _railPadding,
            sliver: SliverList.list(
              children: [
                _ProjectsHeader(
                  onAdd: () => showCreateProjectDialog(context),
                  onManage: () => ref
                      .read(shellSectionProvider.notifier)
                      .select(ShellSection.projects),
                ),
                if (projects.isEmpty)
                  const _AddFirstProjectHint()
                else ...[
                  // Indexed rather than iterated: the guide line running down
                  // this block needs to know which group starts it and which
                  // one ends it, or it dangles up into the "Projects" header
                  // and down into the loose chats — two places the tree does
                  // not reach.
                  for (var i = 0; i < shownProjects; i++)
                    _ProjectGroup(
                      project: projects[i],
                      chats: [
                        for (final c in matches)
                          if (c.projectId == projects[i].id) c,
                      ],
                      isFirst: i == 0,
                      isLast: i == shownProjects - 1,
                    ),
                  // Out at the rail's edge, not indented like the chats just
                  // above it: this reveals more *projects*, and a row sharing
                  // the last project's indent would read as belonging to that
                  // project's chats.
                  if (shownProjects < projects.length)
                    SidebarShowMore(
                      remaining: projects.length - shownProjects,
                      onTap: () => setState(() => _projectPages++),
                    ),
                ],
                SidebarSectionLabel(
                  label: 'Chats',
                  collapsed: !_chatsOpen,
                  onToggle: () => setState(() => _chatsOpen = !_chatsOpen),
                ),
                // Nothing yet, and nothing to say about it — the history is
                // still being read, and "there are none" would be a guess.
                if (!_chatsOpen || (loose.isEmpty && loading))
                  const SizedBox.shrink()
                else if (loose.isEmpty)
                  const _Hint(
                    text: 'Chats outside a project show up here.',
                    indented: true,
                  ),
              ],
            ),
          ),
          // The loose chats are the one part of this rail that grows without a
          // ceiling — a year of chats is a year of rows — so they're built as
          // they're scrolled to rather than all at once on every change to the
          // list. Indented like a project's chats so every conversation's title
          // sits in the same column, whether or not it belongs to a project: the
          // "Chats" and "Projects" labels stay at the outer edge, their contents
          // line up one step in.
          //
          // The "Show more" row is the last item of the same builder rather than
          // a sliver of its own: as one more index it stays glued to the bottom
          // of the chats however many pages are open, and costs nothing on the
          // common case where the whole section fits.
          // Folded away, the section builds nothing at all: this is the one list
          // that can be hundreds of rows, so "collapsed" has to mean gone, not
          // hidden behind a zero height.
          SliverPadding(
            padding: _railPadding,
            sliver: SliverList.builder(
              itemCount: !_chatsOpen
                  ? 0
                  : shownLoose + (shownLoose < loose.length ? 1 : 0),
              itemBuilder: (_, index) => index == shownLoose
                  ? SidebarShowMore(
                      remaining: loose.length - shownLoose,
                      indented: true,
                      onTap: () => setState(() => _loosePages++),
                    )
                  : _ChatRow(chat: loose[index], indented: true),
            ),
          ),
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
  Widget build(BuildContext context) => RailSectionHeader(
    label: 'Projects',
    onTap: onManage,
    tooltip: 'Manage projects',
    onAdd: onAdd,
    addTooltip: 'Add a folder as a project',
  );
}

/// One project and the chats inside it. Collapsible, because a folder you're not
/// working in today shouldn't cost you half the rail.
class _ProjectGroup extends ConsumerStatefulWidget {
  const _ProjectGroup({
    required this.project,
    required this.chats,
    required this.isFirst,
    required this.isLast,
  });

  final Project project;
  final List<Conversation> chats;

  /// Where this group sits in the Projects block, which is all the guide line
  /// needs to know to start and stop in the right place: the first group has
  /// nothing above it to join, and only the last one may end the line.
  final bool isFirst;
  final bool isLast;

  @override
  ConsumerState<_ProjectGroup> createState() => _ProjectGroupState();
}

class _ProjectGroupState extends ConsumerState<_ProjectGroup> {
  bool _open = true;

  // How many pages of this project's chats have been opened. Per group, so
  // paging one busy project open doesn't unfold every other project too.
  int _pages = 1;

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
    final missing = watchProjectMissing(ref, widget.project);
    final chats = widget.chats;
    final shown = sidebarPageCount(_pages, chats.length);
    // How many rows hang off the trunk under this project — its chats, or the
    // "Show more" closing them, or the one line saying there are none. Counted
    // up front because only the *last* of them may end the guide line, and a
    // collapsed group has none at all: the line then stops at the folder icon.
    final branches = !open
        ? 0
        : chats.isEmpty
        ? 1
        : shown + (shown < chats.length ? 1 : 0);
    // The last branch of the last group is where the tree ends. Everything
    // above it carries the line on to whatever comes next.
    final endsAt = widget.isLast ? branches - 1 : -1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarTimeline(
          role: SidebarTimelineRole.node,
          above: !widget.isFirst,
          // Only carry the line on if there is something down there to carry it
          // to: another project, or this one's own chats unfolded beneath it.
          below: !widget.isLast || branches > 0,
          child: SidebarItem(
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
                    // The guide sits outside the reveal, not inside it: the
                    // line belongs to the group and is already there, while the
                    // rows are what arrive. Fading and sliding it with them
                    // would break the trunk into drifting pieces for the half
                    // second a project takes to open.
                    if (chats.isEmpty)
                      SidebarTimeline(
                        role: SidebarTimelineRole.branch,
                        below: endsAt != 0,
                        child: const _RevealItem(
                          index: 0,
                          child: _Hint(text: 'No chats yet', indented: true),
                        ),
                      )
                    else ...[
                      for (var i = 0; i < shown; i++)
                        SidebarTimeline(
                          role: SidebarTimelineRole.branch,
                          below: endsAt != i,
                          child: _RevealItem(
                            // Staggered within its page, not within the whole
                            // list: a page revealed later arrives as its own
                            // wave, and the stagger never runs off the end of
                            // the curve table on a project with a hundred chats.
                            // The widest page is the increment, so the modulo is
                            // taken against that rather than the shorter first
                            // page — the curve lookup clamps either way.
                            index: i % kSidebarNextPage,
                            child: _ChatRow(chat: chats[i], indented: true),
                          ),
                        ),
                      if (shown < chats.length)
                        SidebarTimeline(
                          role: SidebarTimelineRole.branch,
                          below: endsAt != shown,
                          child: SidebarShowMore(
                            remaining: chats.length - shown,
                            indented: true,
                            onTap: () => setState(() => _pages++),
                          ),
                        ),
                    ],
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

  /// Same deal as the "…" menu's Archive: no confirm dialog for a reversible
  /// action, the toast carries the way back.
  void _archive(BuildContext context, WidgetRef ref) {
    final id = chat.id;
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reads AppPalette.textFaint — follow theme flips.
    AppTheme.watch(context);
    final controller = ref.read(chatSessionsProvider.notifier);
    // Highlighted only while you're actually *in* the chat: on Plugins or
    // Scheduled the open screen is the one to mark, and two lit rows in one rail
    // would leave you guessing which page you're looking at. The chat stays the
    // one you come back to — it just doesn't claim to be on screen.
    //
    // Both watched unconditionally and selected down to a bool: `&&` would
    // short-circuit the second subscription away on an unselected row, and
    // watching the whole state rebuilt every row on every streamed token.
    final isOpen = ref.watch(
      chatSessionsProvider.select((s) => s.activeId == chat.id),
    );
    // Docs shows the open chat too — in the column beside the document — so a
    // document's row is lit there for the same reason a chat's row is lit in
    // Chat: it is the conversation on screen.
    final section = ref.watch(shellSectionProvider);
    final onScreen =
        section == ShellSection.chat || section == ShellSection.officeDocs;
    final selected = isOpen && onScreen;
    // A reply is coming into this chat — shown on whichever chat is working,
    // open or in the background, now that several can be in flight at once.
    // Selecting on the bool (not the raw phase) keeps the row from rebuilding on
    // every streamed token.
    final working = ref.watch(
      chatSessionsProvider.select((s) => s.sendingFor(chat.id)),
    );
    // A scheduled task's chat with a result the user hasn't opened yet — the dot
    // stays until they read it. Selecting on the bool keeps the row from
    // rebuilding when some *other* task's badge changes.
    final unread = ref.watch(
      taskUnreadProvider.select(
        (s) => s.contains(jobIdOfTaskConversation(chat.id)),
      ),
    );
    // What the hover preview names as the chat's home. A chat whose project was
    // removed reads as loose here for the same reason the rail lists it there.
    final project = ref.watch(projectByIdProvider(chat.projectId));

    return Padding(
      // Line a project's chats up under the project *name*, not under its
      // folder icon: the row's own 10px inset + an 18px icon + a 10px gap put the
      // name's text at 38px, so a 28px indent here lands the chat's text in the
      // same column. Codex keeps this one clean left edge; anything else makes
      // the list read as ragged.
      padding: EdgeInsets.only(left: indented ? 28 : 0),
      // Hovering a row floats the whole title out to the right of the rail,
      // where there's room for it — the rail itself can only ever show the
      // first few words of a conversation's name.
      child: ChatHoverPreview(
        title: chat.title,
        updatedAt: chat.updatedAt,
        // Where this conversation lives, and for a document's chat that is
        // Docs — the same answer the page glyph in its row gives, in words.
        place: chat.documentPath != null ? 'Docs' : project?.name ?? 'Chats',
        placeIcon: chat.documentPath != null
            ? LucideIcons.fileText300
            : project != null
            ? LucideIcons.folder300
            : LucideIcons.messageSquare300,
        child: SidebarItem(
          label: chat.title,
          // Two chats can be six words of the same sentence apart, and the rail
          // shows the first three — so the row itself hands the rest over under
          // the pointer instead of leaving the ellipsis to be argued with.
          revealLabelOnHover: true,
          selected: selected,
          // One slot, three things a row might have to say — in the order they
          // stop mattering.
          //
          // Unread first, muted-accent so it reads as "new" without competing
          // with the selected row's bright rail; hidden the instant the chat is
          // opened (read).
          //
          // Then the page glyph, on a chat that belongs to a document. It is
          // the app's own mark for a document (the Docs row wears it, and so
          // does the bar above the page), and it is the one badge here that
          // says what the row *does*: this one opens Docs with a file beside
          // the conversation, not the Chat screen.
          //
          // Then the pin, when there is nothing more urgent to say — otherwise
          // the top of the rail is a group with no explanation for why those
          // rows are there.
          badge: unread
              ? const StatusDot(color: AppPalette.accent, size: 7)
              : chat.documentPath != null
              ? Icon(
                  LucideIcons.fileText300,
                  size: 12,
                  color: AppPalette.textFaint,
                )
              : chat.pinned
              ? Icon(LucideIcons.pin300, size: 11, color: AppPalette.textFaint)
              : null,
          // A chat started beside a document opens Docs, with that document on
          // the right — see [openChat]. Everything else opens Chat, as before.
          onTap: () => openChat(ref, chat.id),
          // While a reply is coming in, the row shows a live cue instead of the
          // actions — you can't archive mid-reply anyway, and a pulsing cue says
          // "still working" at a glance without hovering. Idle, the row hands
          // over two actions on hover: pin and archive. Both are reversible, so
          // they belong on a list where a mis-aimed click lands on the row below;
          // deleting a transcript stays behind the chat's own "…" menu.
          //
          // Pin sits on the inner edge because it's the one a heavy pin-user
          // reaches for most; the slot widens to fit the pair. Pinning is a rail
          // action, not only a thing buried in the open chat's menu, because the
          // chats worth pinning are the long-running ones you keep coming *back*
          // to from the rail — not the one already on screen.
          trailingWidth: working ? 24 : 50,
          trailingAlwaysVisible: working,
          trailing: working
              ? const _ChatActivityCue()
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _RowActionButton(
                      icon: chat.pinned
                          ? LucideIcons.pinOff300
                          : LucideIcons.pin300,
                      tooltip: chat.pinned ? 'Unpin from top' : 'Pin to top',
                      semanticLabel: chat.pinned ? 'Unpin chat' : 'Pin chat',
                      onTap: () => controller.togglePinned(chat.id),
                    ),
                    const SizedBox(width: 2),
                    _RowActionButton(
                      icon: LucideIcons.archive300,
                      tooltip: 'Archive chat',
                      semanticLabel: 'Archive chat',
                      onTap: () => _archive(context, ref),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The live cue on a chat row while a reply is coming in — a spinning ring so a
/// background chat reads as still working, not stalled. Sits where the archive
/// action would, at the same 24px width, so nothing reflows when it appears.
///
/// The same ring every other running state in the app uses (a step's status
/// glyph, a button mid-work), so "this is going" looks the same wherever you
/// meet it — dots said the same thing in a dialect only this rail spoke.
///
/// Kept muted rather than accented: the selected row already owns the rail's one
/// bright mark, and a second lit element in the list would blur which chat is on
/// screen.
class _ChatActivityCue extends StatelessWidget {
  const _ChatActivityCue();

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette from inside a lazy list's child — watch here or the cue
    // keeps the palette it was first painted with.
    AppTheme.watch(context);
    return Align(
      alignment: Alignment.centerRight,
      child: AppSpinner(size: SpinnerSize.small, color: AppPalette.textFaint),
    );
  }
}

/// One action revealed on a chat row's hover — pin, or archive.
///
/// Built like the project rail's "…" trigger rather than as an [IconButton]:
/// the row's own hover only *reveals* this glyph, so lighting up under the
/// pointer needs a second, button-local hover state. Without it the icon sits
/// at its resting tint while you're aiming at it, and the click target reads as
/// decoration.
///
/// One widget for both actions so the two neighbouring rail buttons can't drift
/// apart in size, hover treatment or ink — they light up identically because
/// they are the same button.
class _RowActionButton extends StatefulWidget {
  const _RowActionButton({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  State<_RowActionButton> createState() => _RowActionButtonState();
}

class _RowActionButtonState extends State<_RowActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppSurface from inside a lazy list's child — watch here
    // or this glyph keeps the palette it was first painted with.
    AppTheme.watch(context);
    final hot = _hovered;
    // Rests at textFaint so it stays a whisper once revealed, and climbs to
    // textPrimary under the pointer — the same destination as the project row's
    // trigger, so two neighbouring rail actions light up identically.
    final ink = hot ? AppPalette.textPrimary : AppPalette.textFaint;

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Tooltip(
        message: widget.tooltip,
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
                // A fill under the glyph as well as the colour lift: on a row
                // that is *already* washed by its own hover, colour alone is a
                // thin signal for "the pointer is on the button, not the row".
                color: hot ? AppSurface.hoverFill : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: Icon(widget.icon, size: 16, color: ink),
            ),
          ),
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
            onPressed: () => showCreateProjectDialog(context),
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

/// The stagger curve per row position, built once.
///
/// A total window a touch longer than one row's animation, so staggering the
/// start by index still lands every row inside it. Capped so a long list never
/// feels slow — past the eighth row there's no extra delay, which is why nine
/// curves cover any length of list.
///
/// Held rather than built per row per build: [Interval] has no value equality,
/// so a fresh one reads as a changed curve and makes every row in the rail throw
/// away and rebuild its animation on each rebuild.
final List<Curve> _revealCurves = List.unmodifiable([
  for (var i = 0; i <= 8; i++)
    Interval(i * 0.12, 1, curve: Curves.easeOutCubic),
]);

class _RevealItemState extends State<_RevealItem> {
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.index),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 460),
      curve: _revealCurves[widget.index.clamp(0, _revealCurves.length - 1)],
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
      // 38, not the 28 a chat row uses: that row hands its indent to a
      // SidebarItem, which adds its own 10px inset before the text. A hint is
      // bare Text with nothing to add that second step, so it has to carry both
      // itself or it hangs 10px left of the chats it sits among.
      padding: EdgeInsets.fromLTRB(indented ? 38 : 10, 4, 10, 6),
      child: Text(
        text,
        style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
