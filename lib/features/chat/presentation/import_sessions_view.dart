import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/import/import_filter.dart';
import '../logic/import/parsed_session.dart';
import '../logic/import/session_import_controller.dart';
import '../logic/import/session_scanner.dart';
import 'import_source_picker.dart';
import 'import_widgets.dart';

/// Settings › Import chats: the conversations Claude Code and Codex have left
/// on this computer, and the one button that turns one into a chat here.
///
/// The screen is a picker rather than a "bring everything in": there are 285
/// sessions on the machine this was built on, most of them one question long,
/// and several run to megabytes. Importing the lot would be a slower app
/// forever in exchange for a history nobody asked for — so every row is a
/// choice, and the row says what it costs before it is made.
class ImportSessionsView extends ConsumerStatefulWidget {
  const ImportSessionsView({super.key});

  @override
  ConsumerState<ImportSessionsView> createState() => _ImportSessionsViewState();
}

class _ImportSessionsViewState extends ConsumerState<ImportSessionsView> {
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  ImportQuery _query = const ImportQuery();

  /// The tool whose sessions are being listed, or null on the picker.
  ///
  /// The screen is two states rather than one dense list. There are 286
  /// sessions on this computer, and a wall of them behind a segmented control
  /// asks the user to filter before they have been told what this screen even
  /// does. The picker says that in two cards; the list is one click in, already
  /// narrowed to the tool they picked.
  ImportedAgent? _source;

  /// Add the folder each imported session ran in to the user's projects.
  ///
  /// On by default, and said out loud on the control: it is what makes an
  /// imported chat continuable, because the agent resumes a session *in a
  /// folder* and a chat with no project runs in the app's own workspace
  /// instead. Off is for the user who wants the transcript and not a Projects
  /// list full of folders they last opened in March.
  bool _linkProjects = true;

  /// The sessions being read right now, by row key — one row can be importing
  /// while the user reads another.
  final _busy = <String>{};

  @override
  void dispose() {
    _search.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _keyOf(DiscoveredSession session) =>
      '${session.agent.id}|${session.sessionId}';

  Future<void> _import(ImportableSession row) async {
    final key = _keyOf(row.session);
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    final failure = await ref
        .read(sessionImportProvider.notifier)
        .import(row.session, linkProject: _linkProjects);
    if (!mounted) return;
    setState(() => _busy.remove(key));

    if (failure != null) {
      ToastScope.show(context, ToastSpec(message: failure));
      return;
    }
    // The chat is in the sidebar now, but the user is looking at Settings —
    // so the toast is what says where it went, and offers to take them there.
    ToastScope.show(
      context,
      ToastSpec(
        message: '"${row.session.title}" is now a chat',
        action: ToastAction(
          label: 'Open',
          onPressed: () => _open(_importedId(row.session)),
        ),
      ),
    );
  }

  /// The chat an already-imported row became, re-read after the import so the
  /// toast's Open button points at a chat that exists.
  String? _importedId(DiscoveredSession session) {
    final rows = ref.read(sessionImportProvider).value ?? const [];
    for (final row in rows) {
      if (_keyOf(row.session) == _keyOf(session)) return row.conversationId;
    }
    return null;
  }

  /// Bring over everything that tool has, after saying how much that is.
  ///
  /// The confirmation is not ceremony. Every imported chat is read back into
  /// memory on every launch (see `ChatStore.loadAll`), so agreeing to two
  /// hundred of them is agreeing to carry them at every start — a cost the user
  /// pays later and should be told about now, with the number in front of them.
  Future<void> _syncAll(ImportedAgent agent) async {
    final rows = ref.read(sessionImportProvider).value ?? const [];
    final pending = [
      for (final row in rows)
        if (row.session.agent == agent && row.isActionable) row.session,
    ];
    if (pending.isEmpty) return;

    var bytes = 0;
    for (final session in pending) {
      bytes += session.sizeBytes;
    }
    final ok = await _confirmSync(
      context,
      agent: agent,
      count: pending.length,
      bytes: bytes,
      linkProjects: _linkProjects,
    );
    if (!ok || !mounted) return;

    final outcome = await ref
        .read(sessionImportProvider.notifier)
        .syncAll(agent, linkProject: _linkProjects);
    if (!mounted) return;
    ToastScope.show(context, ToastSpec(message: _syncSummary(outcome)));
  }

  /// What the sync actually did, in one line.
  ///
  /// The failures are named rather than folded into a cheerful total. A run
  /// that skipped three sessions and said "all your conversations are here" is
  /// the exact shape of copy the conventions call a bug rather than a wording
  /// problem — and the three would sit in the list afterwards, contradicting it.
  String _syncSummary(SyncOutcome outcome) {
    final brought = outcome.imported == 1
        ? '1 conversation'
        : '${outcome.imported} conversations';
    final stopped = outcome.stopped ? 'Stopped — ' : '';
    if (outcome.failed == 0) {
      return outcome.imported == 0
          ? '${stopped}Nothing was brought over'
          : '$stopped$brought brought over';
    }
    final skipped = outcome.failed == 1
        ? "1 couldn't be read"
        : "${outcome.failed} couldn't be read";
    return '$stopped$brought brought over  ·  $skipped';
  }

  void _openSource(ImportedAgent agent) {
    _search.clear();
    setState(() {
      _source = agent;
      // The list is *of* that tool, so the agent filter is the choice already
      // made rather than a control to repeat.
      _query = ImportQuery(agent: agent.filter);
    });
  }

  void _backToSources() {
    _search.clear();
    setState(() {
      _source = null;
      _query = const ImportQuery();
    });
  }

  void _open(String? conversationId) {
    if (conversationId == null) return;
    ref.read(chatSessionsProvider.notifier).select(conversationId);
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette below — follow theme flips.
    AppTheme.watch(context);
    final sessions = ref.watch(sessionImportProvider);

    final source = _source;
    return SectionScaffold(
      title: source == null ? 'Import chats' : source.label,
      subtitle: source == null
          ? 'Conversations you have already had with Claude Code and Codex on '
                'this computer. Bring one in and it becomes a chat here — with '
                'the thread it came from, so you can carry on where you left '
                'off.'
          : 'Pick the conversations to bring over. Each one becomes a chat you '
                'can read, search and carry on.',
      child: switch (sessions) {
        AsyncLoading() => const Center(
          child: AppSpinner(size: SpinnerSize.large),
        ),
        AsyncError(:final error) => Align(
          alignment: Alignment.topCenter,
          child: ErrorBox(
            message:
                "Couldn't read the session folders on this computer: $error",
          ),
        ),
        AsyncValue(:final value) when source == null => SourcePicker(
          rows: value ?? const [],
          progress: ref.watch(importProgressProvider),
          onRefresh: () => ref.read(sessionImportProvider.notifier).refresh(),
          onPick: _openSource,
          onSync: _syncAll,
          onStop: () => ref.read(importProgressProvider.notifier).cancel(),
        ),
        AsyncValue(:final value) => _Body(
          rows: value ?? const [],
          onBack: _backToSources,
          query: _query,
          search: _search,
          scrollController: _scrollController,
          busy: _busy,
          linkProjects: _linkProjects,
          keyOf: _keyOf,
          onQueryChanged: (next) => setState(() => _query = next),
          onLinkProjectsChanged: (value) =>
              setState(() => _linkProjects = value),
          onRefresh: () => ref.read(sessionImportProvider.notifier).refresh(),
          onImport: _import,
          onOpen: _open,
        ),
      },
    );
  }
}

/// Everything below the header once the scan has landed.
class _Body extends StatelessWidget {
  const _Body({
    required this.rows,
    required this.onBack,
    required this.query,
    required this.search,
    required this.scrollController,
    required this.busy,
    required this.linkProjects,
    required this.keyOf,
    required this.onQueryChanged,
    required this.onLinkProjectsChanged,
    required this.onRefresh,
    required this.onImport,
    required this.onOpen,
  });

  final List<ImportableSession> rows;
  final VoidCallback onBack;
  final ImportQuery query;
  final TextEditingController search;
  final ScrollController scrollController;
  final Set<String> busy;
  final bool linkProjects;
  final String Function(DiscoveredSession) keyOf;
  final ValueChanged<ImportQuery> onQueryChanged;
  final ValueChanged<bool> onLinkProjectsChanged;
  final VoidCallback onRefresh;
  final ValueChanged<ImportableSession> onImport;
  final ValueChanged<String?> onOpen;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Neither tool has been used on this computer — or neither is installed.
    // The controls are hidden rather than disabled, for the same reason the
    // Archived screen hides its own: a filter that can only narrow nothing to
    // nothing is an invitation to a dead end.
    if (rows.isEmpty) return const NothingFound();

    final matches = filterImportable(rows, query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackRow(onBack: onBack),
        const SizedBox(height: 14),
        _Controls(
          query: query,
          search: search,
          linkProjects: linkProjects,
          onChanged: onQueryChanged,
          onLinkProjectsChanged: onLinkProjectsChanged,
          onRefresh: onRefresh,
        ),
        const SizedBox(height: 14),
        Expanded(
          child: matches.isEmpty
              // Filtered to nothing — the opposite case to the one above, and
              // the controls stay so there is a way back to a list.
              ? const EmptyState.noMatches(
                  message: 'No session matches these filters.',
                  compact: false,
                )
              : Scrollbar(
                  controller: scrollController,
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final row = matches[index];
                      return _SessionRow(
                        row: row,
                        busy: busy.contains(keyOf(row.session)),
                        onImport: () => onImport(row),
                        onOpen: () => onOpen(row.conversationId),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// Search, what to hide, whether to link folders, and a re-scan.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.query,
    required this.search,
    required this.linkProjects,
    required this.onChanged,
    required this.onLinkProjectsChanged,
    required this.onRefresh,
  });

  final ImportQuery query;
  final TextEditingController search;
  final bool linkProjects;
  final ValueChanged<ImportQuery> onChanged;
  final ValueChanged<bool> onLinkProjectsChanged;
  final VoidCallback onRefresh;

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
                  decoration:
                      labeledFieldDecoration(
                        'Search by what it was about, or the folder',
                      ).copyWith(
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
            RefreshButton(onPressed: onRefresh),
          ],
        ),
        const SizedBox(height: 12),
        // Wrap so a narrow settings pane reflows the controls instead of
        // overflowing them.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PillChoice(
              label: const Text('Hide imported'),
              selected: query.hideImported,
              onTap: () =>
                  onChanged(query.copyWith(hideImported: !query.hideImported)),
            ),
            Tooltip(
              message: linkProjects
                  ? "Each chat's folder is added to your projects, which is "
                        'what lets you carry the conversation on'
                  : 'Chats come in without a project — you can read them, but '
                        'a new message starts a fresh session',
              child: _CheckRow(
                label: 'Add folder to Projects',
                checked: linkProjects,
                onTap: () => onLinkProjectsChanged(!linkProjects),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The way back to the two cards.
class _BackRow extends StatefulWidget {
  const _BackRow({required this.onBack});

  final VoidCallback onBack;

  @override
  State<_BackRow> createState() => _BackRowState();
}

class _BackRowState extends State<_BackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onBack,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.chevronLeft300,
                  size: 15,
                  color: _hovered
                      ? AppPalette.textPrimary
                      : AppPalette.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'All sources',
                  style: TextStyle(
                    color: _hovered
                        ? AppPalette.textPrimary
                        : AppPalette.textSecondary,
                    fontSize: 13,
                    fontWeight: AppFont.medium,
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

/// A setting, not an action.
///
/// It was a filled accent pill, which put it beside the row buttons in weight
/// and read as the screen's primary call to action — the thing you press. It
/// governs what the *Import* buttons do, so it has to look like a switch that
/// is on, not like a button competing with them.
class _CheckRow extends StatefulWidget {
  const _CheckRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Semantics(
      checked: widget.checked,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : AppGlass.surfaceFill,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The box is the only accent on the control, and it is a fill
                // under a white tick — the one use `AppPalette.accent` is for.
                AnimatedContainer(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  width: 15,
                  height: 15,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.checked ? AppPalette.accent : AppCard.inset,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: widget.checked
                      ? const Icon(
                          LucideIcons.check300,
                          size: 11,
                          color: Colors.white,
                        )
                      : null,
                ),
                const SizedBox(width: 9),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.checked
                        ? AppPalette.textPrimary
                        : AppPalette.textSecondary,
                    fontSize: 13,
                    fontWeight: AppControl.fontWeight,
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

/// One session: which tool it was, what it was about, where it ran, and the one
/// thing to do with it.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.row,
    required this.busy,
    required this.onImport,
    required this.onOpen,
  });

  final ImportableSession row;
  final bool busy;
  final VoidCallback onImport;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // Item of a lazy list — it must watch for itself, or it stays on the
    // palette it first built in when the theme flips.
    AppTheme.watch(context);
    final session = row.session;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 11, 11),
        decoration: BoxDecoration(
          // A raised block, so it reads as a card on the settings page — fill
          // alone is ~1.05:1 against the page and would be invisible without
          // the shadow.
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
                  Row(
                    children: [
                      _AgentBadge(agent: session.agent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 13.5,
                            fontWeight: AppFont.medium,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _metaLine(session),
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
            _RowAction(
              row: row,
              busy: busy,
              onImport: onImport,
              onOpen: onOpen,
            ),
          ],
        ),
      ),
    );
  }

  /// Where it ran, when it was last talked in, and how big it is — the three
  /// facts that decide whether this is the session the user is looking for and
  /// whether they want it in their history.
  static String _metaLine(DiscoveredSession session) {
    final parts = <String>[
      if (session.folderName.isNotEmpty) session.folderName,
      whenLabel(session.updatedAt),
      sizeLabel(session.sizeBytes),
    ];
    return parts.join('  ·  ');
  }
}

/// Which tool wrote the session — a quiet chip, since the list is usually
/// filtered to one of them anyway.
class _AgentBadge extends StatelessWidget {
  const _AgentBadge({required this.agent});

  final ImportedAgent agent;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        agent.label,
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 11,
          fontWeight: AppFont.medium,
        ),
      ),
    );
  }
}

/// The one action a row offers, which is decided by what has already been done
/// with it.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.row,
    required this.busy,
    required this.onImport,
    required this.onOpen,
  });

  final ImportableSession row;
  final bool busy;
  final VoidCallback onImport;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (busy) {
      return const SizedBox(
        height: AppControl.heightSmall,
        width: 78,
        child: Center(child: AppSpinner(size: SpinnerSize.small)),
      );
    }

    return switch (row.status) {
      // Never imported: the plain, primary action.
      ImportStatus.fresh => _ActionButton(
        label: 'Import',
        primary: true,
        onPressed: onImport,
      ),
      // Imported, then talked in again over there. "Update" rather than
      // "Import again", because the chat it made is not replaced by a second
      // one — it grows by whatever was said since.
      ImportStatus.changed => _PendingAction(
        note: 'New messages',
        tooltip: 'This session has been talked in since it was imported',
        onPressed: onImport,
      ),
      // Imported, unchanged, but by an older importer. The note says what is
      // actually on offer — not "new messages", which would be a lie about a
      // file nobody has touched.
      ImportStatus.outdated => _PendingAction(
        note: 'Better import available',
        tooltip:
            'This chat was brought over by an older version of the importer — '
            'updating rebuilds it, and keeps the same chat',
        onPressed: onImport,
      ),
      // Nothing to do — so the row says so and offers the way to the chat
      // instead of a button that would rewrite an identical file.
      ImportStatus.imported => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.check300, size: 15, color: AppPalette.online),
          const SizedBox(width: 6),
          Text(
            'Imported',
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
          ),
          const SizedBox(width: 10),
          _ActionButton(label: 'Open', primary: false, onPressed: onOpen),
        ],
      ),
    };
  }
}

/// A row that has already been imported but has something more on offer: a note
/// saying what, and the button that takes it.
class _PendingAction extends StatelessWidget {
  const _PendingAction({
    required this.note,
    required this.tooltip,
    required this.onPressed,
  });

  final String note;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: Text(
            note,
            style: TextStyle(
              // Accent *on a surface*, never the flat accent — that one is a
              // fill under white text and reads at 2.6:1 as text on dark.
              color: AppPalette.accentOnSurface,
              fontSize: 12.5,
              fontWeight: AppFont.medium,
            ),
          ),
        ),
        const SizedBox(width: 10),
        _ActionButton(label: 'Update', primary: true, onPressed: onPressed),
      ],
    );
  }
}

/// A row button. Primary is the accent fill; secondary is the inset card, the
/// same pair the Archived screen uses for its own two.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.primary,
    required this.onPressed,
  });

  final String label;
  final bool primary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        // White on the accent fill, which is the one place `accent` is allowed
        // — as a fill under white text, never as text on a surface.
        foregroundColor: primary ? Colors.white : AppPalette.textPrimary,
        backgroundColor: primary ? AppPalette.accent : AppCard.inset,
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
      ),
      child: Text(label),
    );
  }
}

/// Ask before a sync, naming what it will bring and what it will cost.
///
/// The size is the *source* size, which overstates the chats by roughly a
/// quarter — the transcripts drop tool output and reasoning. Overstating is the
/// right direction for a number in a confirmation: the surprise it prevents is
/// "this took more than you said", never the reverse.
Future<bool> _confirmSync(
  BuildContext context, {
  required ImportedAgent agent,
  required int count,
  required int bytes,
  required bool linkProjects,
}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      AppTheme.watch(context);
      final theme = Theme.of(context);
      return AlertDialog(
        // Lifted off the window, like the app's other dialogs.
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
              ? 'Bring over 1 conversation?'
              : 'Bring over $count conversations?',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Everything ${agent.label} has on this computer that is not '
                'already here — about ${sizeLabel(bytes)} of transcripts. They '
                'become chats you can read, search and carry on, and your app '
                'reads all of them each time it starts.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                  height: 1.45,
                ),
              ),
              if (linkProjects) ...[
                const SizedBox(height: 10),
                Text(
                  "Each conversation's folder is added to your projects, so you "
                  'can carry it on where it left off.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textFaint,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Bring them over'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
