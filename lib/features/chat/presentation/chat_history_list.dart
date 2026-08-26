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
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/presentation/agent_mark.dart';
import '../../projects/logic/project.dart';
import '../../projects/logic/project_folder_status.dart';
import '../../projects/presentation/create_project_dialog.dart';
import '../../projects/presentation/project_menu.dart';
import '../../scheduled/logic/task_conversation_id.dart';
import '../../scheduled/logic/task_unread_store.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'chat_header.dart';
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
  // upstream: having asked to see more chats, you don't expect the list to fold
  // back up because one of them finished replying.
  //
  // Only [_loosePages] is ever put back, and only by folding the section away
  // ([_toggleChats]). The project *list* has no fold to reset it, so once it
  // has grown it stays grown.
  int _projectPages = 1;
  int _loosePages = 1;

  // Whether the loose-chat section is unfolded. A project row folds the chats
  // under it, so the one group in the rail that *couldn't* fold read as an
  // oversight — and it's the group most likely to be hundreds of rows long.
  bool _chatsOpen = true;

  /// Fold the loose chats away, or open them again at their first page.
  ///
  /// Putting a section away discards how far it had been paged open, exactly as
  /// a project group does — see [_ProjectGroupState._toggle] for why the two
  /// have to agree on that.
  void _toggleChats() {
    setState(() {
      _chatsOpen = !_chatsOpen;
      if (!_chatsOpen) _loosePages = 1;
    });
  }

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
    // its identity is the change signal — which is why this reads
    // [ChatSessionsState.railConversations], whose whole job is to hand back one
    // field or the other rather than a list built here.
    final conversations = ref.watch(
      chatSessionsProvider.select((s) => s.railConversations),
    );
    // The saved chats are read off the first frame, so an empty list is two
    // different facts — nothing saved, or nothing read *yet*. Only the first of
    // them may be told to the user. Once the index has been read the rail has
    // its rows and is no longer waiting on anything, however much of the history
    // is still being decoded behind it.
    final loading = ref.watch(
      chatSessionsProvider.select((s) => s.loading && s.preview.isEmpty),
    );
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
    // The loose chats open far wider than the project list above them
    // ([kSidebarChatsFirstPage] rather than [kSidebarFirstPage]), which is also
    // what keeps a short history whole: under twenty chats nothing is hidden and
    // no "Show more" is built at all. Past that it still grows ten at a click.
    final shownLoose = sidebarPageCount(
      _loosePages,
      loose.length,
      firstPage: kSidebarChatsFirstPage,
    );

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
                  onToggle: _toggleChats,
                ),
              ],
            ),
          ),
          // One box rather than a lazy sliver, which is what lets this section
          // fold like a project instead of blinking — see [_LooseChats] for the
          // trade that buys it, and for why the page cap above keeps it cheap.
          SliverPadding(
            padding: _railPadding,
            sliver: SliverToBoxAdapter(
              child: _LooseChats(
                chats: loose,
                shown: shownLoose,
                open: _chatsOpen,
                loading: loading,
                onShowMore: () => setState(() => _loosePages++),
              ),
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
  // paging one busy project open doesn't unfold every other project too, and
  // put back whenever the group is folded away — see [_toggle].
  int _pages = 1;

  /// Fold the group, or open it again at its first page.
  ///
  /// Reopening starts over rather than restoring however far the chats had been
  /// paged: folding a project is how a person gives the rail its room back, and
  /// a folder that came back twenty rows deep would take that room away again on
  /// the click that was meant to be a peek. Nobody is holding "how many times I
  /// pressed Show more last week" in their head either, so there is no state
  /// here worth preserving against the cost of restoring it.
  void _toggle() {
    setState(() {
      _open = !_open;
      if (!_open) _pages = 1;
    });
  }

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
            onTap: _toggle,
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
        //
        // [_LooseChats] folds on this same duration and curve, from the shared
        // token rather than from a copy of the number: a rail where two groups
        // open at almost the same speed reads as one of them lagging.
        AnimatedSize(
          duration: AppMotion.fold,
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
                        _ChatBranch(
                          chat: chats[i],
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

/// The "Chats" section's body: every conversation that belongs to no project,
/// then the "Show more" that closes the list while there is more of it.
///
/// Folds on the same duration, curve and per-row wave a project group does, and
/// for the same reason it does: the header above this one is the same gesture,
/// so a section that blinked open while every project glided was the rail's one
/// group behaving differently for no reason a user could see.
///
/// **This is the one part of the rail built in one piece rather than as it is
/// scrolled to**, and that is the price of the fold: [AnimatedSize] animates
/// between two heights it has to measure, and a lazy sliver has no height to
/// measure until you have already scrolled to the end of it. What keeps the
/// trade cheap is the page cap this section already had — it mounts
/// [kSidebarChatsFirstPage] rows and grows by [kSidebarNextPage] only when
/// someone clicks for more, so the year of chats this list can hold is never
/// mounted unless a person asked for it ten rows at a time. Collapsed, it builds
/// nothing at all.
class _LooseChats extends StatelessWidget {
  const _LooseChats({
    required this.chats,
    required this.shown,
    required this.open,
    required this.loading,
    required this.onShowMore,
  });

  /// Every loose chat. Only the first [shown] of them are drawn.
  final List<Conversation> chats;
  final int shown;

  /// Whether the "Chats" header is unfolded.
  final bool open;

  /// The saved history is still being read, so an empty list is "not yet" as
  /// easily as "there are none" — and only the second may be told to the user.
  final bool loading;

  final VoidCallback onShowMore;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.fold,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !open
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chats.isEmpty && !loading)
                  const _RevealItem(
                    index: 0,
                    child: _Hint(
                      text: 'Chats outside a project show up here.',
                      indented: true,
                    ),
                  ),
                // Indented like a project's chats, so every conversation's title
                // sits in the same column whether or not it belongs to a
                // project: the "Chats" and "Projects" labels stay out at the
                // rail's edge, their contents line up one step in.
                for (var i = 0; i < shown; i++)
                  // No guide line out here — a loose chat is in no tree — but
                  // the same mark in the same column, so a chat's assistant is
                  // read off the same place whether or not it has a project.
                  _ChatBranch(
                    chat: chats[i],
                    child: _RevealItem(
                      // The wave restarts every [kSidebarNextPage] rows instead
                      // of running the length of the list. The curve table
                      // clamps past the eighth row, so one ramp over a
                      // twenty-row first page would land the last twelve
                      // together anyway — two short waves read as a list
                      // arriving, one long one reads as a list stalling.
                      index: i % kSidebarNextPage,
                      child: _ChatRow(chat: chats[i], indented: true),
                    ),
                  ),
                // Last, so it stays glued to the bottom of the chats however
                // many pages are open, and costs nothing in the common case
                // where the whole section fits.
                if (shown < chats.length)
                  SidebarShowMore(
                    remaining: chats.length - shown,
                    indented: true,
                    onTap: onShowMore,
                  ),
              ],
            ),
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
      // first few words of a conversation's name. Right-clicking it opens the
      // chat's own menu, the same one the header's "…" opens.
      child: _ChatRowSurface(
        chat: chat,
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
          // the pointer instead of leaving the fade to be argued with.
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
          //
          // The agent's mark is not here. It sits out in the gutter, on the
          // guide line, in the column the folder icons hold — see [_ChatBranch].
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

/// What a chat's row hangs in: its hover preview, and the right-click that opens
/// the chat's menu.
///
/// Both are about the row without being *in* it, so they sit outside
/// [SidebarItem] rather than growing it a second set of parameters — the rail's
/// nav entries and its New chat row use the same item and want neither.
///
/// The one piece of state is which of the two is speaking. A menu opened at the
/// pointer covers the space the preview floats in, and the pointer is by
/// definition still on the row, so without this the card sits under the menu
/// answering a question nobody asked any more.
class _ChatRowSurface extends StatefulWidget {
  const _ChatRowSurface({
    required this.chat,
    required this.place,
    required this.placeIcon,
    required this.child,
  });

  final Conversation chat;

  /// Where the chat lives, for the preview card — its project, or the section
  /// holding the chats that belong to none.
  final String place;
  final IconData placeIcon;

  /// The row itself.
  final Widget child;

  @override
  State<_ChatRowSurface> createState() => _ChatRowSurfaceState();
}

class _ChatRowSurfaceState extends State<_ChatRowSurface> {
  bool _menuOpen = false;

  void _setMenuOpen(bool value) {
    if (_menuOpen == value) return;
    setState(() => _menuOpen = value);
  }

  @override
  Widget build(BuildContext context) => ChatMenuAnchor(
    conversation: widget.chat,
    onOpen: () => _setMenuOpen(true),
    onClose: () => _setMenuOpen(false),
    builder: (context, controller, openAt) => GestureDetector(
      // Secondary only: the row's own tap opens the chat, and it belongs to
      // the item's InkWell — a detector claiming the primary button here would
      // take the press feedback and the ink with it.
      onSecondaryTapDown: (details) => openAt(details.globalPosition),
      child: ChatHoverPreview(
        title: widget.chat.title,
        updatedAt: widget.chat.updatedAt,
        place: widget.place,
        placeIcon: widget.placeIcon,
        suppressed: _menuOpen,
        child: widget.child,
      ),
    ),
  );
}

/// The agent mark's size. Smaller than the 18px folder glyph whose column it
/// borrows, so the guide line clears it by a few pixels either side rather than
/// appearing to touch it.
const double _agentMarkSize = 14;

/// The column the mark is centred in — [SidebarItem]'s own icon gutter and the
/// 18px glyph that sits in it, which is what puts the mark's centre on the
/// guide's trunk (`sidebar_timeline.dart` derives that from the same two
/// numbers). Written as the box rather than as "19", so moving the rail's inset
/// moves the mark with the line instead of leaving it beside one.
const double _agentMarkBox = 18;

/// One chat in the rail: the row, the guide line beside it when the chat is
/// inside a project, and the agent's mark — out in the gutter, on the line, in
/// the column the folder icons hold.
///
/// **The mark is here rather than in the row** for two reasons that are really
/// one. It has to sit *outside* [SidebarItem]'s box, or it would push every
/// chat title 28px right and out of the column its project's name sits in. And
/// it has to be painted *after* [SidebarTimeline], whose guide is a
/// `foregroundPainter` — a mark drawn anywhere inside the row would have the
/// trunk drawn straight through it.
///
/// While the mark is showing, the row **is** a node on that line: the guide
/// breaks around the logo instead of striking it out, and the arm — which
/// exists to point at a nested row's left edge — has nothing left to say once
/// something is standing there. At rest the line goes back to being a plain
/// branch, so the tree looks exactly as it did.
class _ChatBranch extends StatefulWidget {
  const _ChatBranch({required this.chat, required this.child, this.below});

  final Conversation chat;

  /// The row, already wrapped in whatever the list puts around it.
  final Widget child;

  /// Whether the project's guide carries on below this row — null for a chat
  /// that belongs to no project, which is in no tree and gets no line.
  final bool? below;

  @override
  State<_ChatBranch> createState() => _ChatBranchState();
}

class _ChatBranchState extends State<_ChatBranch> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    // Which assistant this conversation belongs to — read off the chat itself,
    // never off the picker: the rail lists chats started by all of them at
    // once, and the picker only ever describes the next one.
    final agent = agentOfChat(widget.chat);
    final below = widget.below;
    final showMark = agent != null && _hovered;
    final row = below == null
        ? widget.child
        : SidebarTimeline(
            role: showMark
                ? SidebarTimelineRole.node
                : SidebarTimelineRole.branch,
            below: below,
            child: widget.child,
          );
    if (agent == null) return row;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Stack(
        // Passthrough, not the default loose: the rail hands its rows a tight
        // width and a `Stack` that loosened it would let the row shrink to the
        // width of its own title, leaving every hover fill ragged.
        fit: StackFit.passthrough,
        children: [
          row,
          Positioned(
            left: SidebarItem.iconGutter,
            top: 0,
            bottom: 0,
            width: _agentMarkBox,
            // On the rail's own hover beat, so the mark arrives with the row's
            // wash rather than a frame ahead of it. Kept mounted at zero rather
            // than swapped in, or the guide's gap would open onto nothing while
            // the image decoded.
            child: AnimatedOpacity(
              opacity: showMark ? 1 : 0,
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              child: Center(
                // Named for screen readers: a logo says which assistant to
                // anyone who recognises it and nothing at all to anyone who
                // doesn't.
                child: Semantics(
                  label: agent.name,
                  child: AgentMark(tool: agent, size: _agentMarkSize),
                ),
              ),
            ),
          ),
        ],
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
