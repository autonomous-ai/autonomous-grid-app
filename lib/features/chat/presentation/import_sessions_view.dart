import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
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

    return SectionScaffold(
      title: 'Import chats',
      subtitle:
          'Conversations you have already had with Claude Code and Codex on '
          'this computer. Bring one in and it becomes a chat here — with the '
          'thread it came from, so you can carry on where you left off.',
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
        AsyncValue(:final value) => _Body(
          rows: value ?? const [],
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
    if (rows.isEmpty) return const _NothingFound();

    final matches = filterImportable(rows, query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Controls(
          rows: rows,
          query: query,
          search: search,
          linkProjects: linkProjects,
          onChanged: onQueryChanged,
          onLinkProjectsChanged: onLinkProjectsChanged,
          onRefresh: onRefresh,
        ),
        const SizedBox(height: 12),
        const _WhatComesOver(),
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

/// Search, the two filters, the project switch, and a re-scan.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.rows,
    required this.query,
    required this.search,
    required this.linkProjects,
    required this.onChanged,
    required this.onLinkProjectsChanged,
    required this.onRefresh,
  });

  final List<ImportableSession> rows;
  final ImportQuery query;
  final TextEditingController search;
  final bool linkProjects;
  final ValueChanged<ImportQuery> onChanged;
  final ValueChanged<bool> onLinkProjectsChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    const filters = ImportAgentFilter.values;
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
            _RefreshButton(onPressed: onRefresh),
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
            AppSegmented(
              segments: [
                for (final filter in filters)
                  SegmentSpec(
                    label: filter.label,
                    count: countFor(rows, filter),
                  ),
              ],
              selected: filters.indexOf(query.agent),
              onChanged: (index) =>
                  onChanged(query.copyWith(agent: filters[index])),
            ),
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
              child: PillChoice(
                label: const Text('Add folder to Projects'),
                icon: LucideIcons.folderPlus300,
                selected: linkProjects,
                onTap: () => onLinkProjectsChanged(!linkProjects),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What an import does and does not bring with it.
///
/// Said before the button is pressed rather than discovered afterwards: an
/// imported transcript is *not* byte-for-byte what the other tool shows, and a
/// user who finds that out by scrolling one has been misled by omission. Muted
/// and one line, because it is a caveat, not a warning — nothing here goes
/// wrong, some of it simply doesn't come across.
class _WhatComesOver extends StatelessWidget {
  const _WhatComesOver();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            LucideIcons.info300,
            size: 14,
            color: AppPalette.textFaint,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Messages come across in full. Each command the assistant ran '
            'becomes a one-line note — what it printed, and any images, stay '
            'in the original.',
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// Re-run the scan. The other tools are running while this screen is open, so
/// what it lists goes stale as the user reads it.
class _RefreshButton extends StatefulWidget {
  const _RefreshButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: 'Look for sessions again',
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
            height: AppControl.heightField,
            width: AppControl.heightField,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : AppPalette.cardBg,
              borderRadius: BorderRadius.circular(AppControl.radius),
            ),
            child: Icon(
              LucideIcons.refreshCw300,
              size: AppControl.iconSize,
              // Full colour under the pointer — an icon that stays faint while
              // it is being pointed at reads as decoration.
              color: _hovered
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
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
      ImportStatus.changed => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'This session has been talked in since it was imported',
            child: Text(
              'New messages',
              style: TextStyle(
                color: AppPalette.accentOnSurface,
                fontSize: 12.5,
                fontWeight: AppFont.medium,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _ActionButton(label: 'Update', primary: true, onPressed: onImport),
        ],
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

/// Neither tool has left anything on this computer.
class _NothingFound extends StatelessWidget {
  const _NothingFound();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.download_outlined,
      title: 'No sessions to import',
      message:
          'Nothing was found in the folders Claude Code and Codex keep their '
          'conversations in. Once you have used either of them on this '
          'computer, their chats show up here.',
    );
  }
}

/// A file size in the units a person reads — no decimals below a megabyte,
/// where the digit after the point is noise.
String sizeLabel(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / kb).round()} KB';
}

/// When a session was last talked in, in words.
String whenLabel(DateTime at) {
  final now = DateTime.now();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  return switch (days) {
    <= 0 => 'today',
    1 => 'yesterday',
    < 7 => '$days days ago',
    < 30 => '${days ~/ 7} ${days ~/ 7 == 1 ? 'week' : 'weeks'} ago',
    _ => '${at.day}/${at.month}/${at.year}',
  };
}
