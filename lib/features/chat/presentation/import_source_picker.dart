import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/import/import_filter.dart';
import '../logic/import/parsed_session.dart';
import '../logic/import/session_import_controller.dart';
import 'import_widgets.dart';

/// The screen's first state: one card per tool, and nothing else.
///
/// It answers "what is this screen for" in a glance and defers "which of my 286
/// conversations" to the list behind it. The counts are on the cards so the
/// choice is informed — a tool you have never used says so before it is opened.
class SourcePicker extends StatelessWidget {
  const SourcePicker({
    super.key,
    required this.rows,
    required this.progress,
    required this.onRefresh,
    required this.onPick,
    required this.onSync,
    required this.onStop,
  });

  final List<ImportableSession> rows;

  /// The sync running now, or null. Only one runs at a time — two would fight
  /// over the same chat folder and the same ledger file.
  final ImportProgress? progress;

  final VoidCallback onRefresh;

  /// Open this tool's list, to pick conversations one at a time.
  final ValueChanged<ImportedAgent> onPick;

  /// Bring over everything this tool has that isn't here yet.
  final ValueChanged<ImportedAgent> onSync;

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (rows.isEmpty) return const NothingFound();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final agent in ImportedAgent.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SourceCard(
              agent: agent,
              total: countFor(rows, agent.filter),
              imported: _importedCount(agent),
              pending: _pendingCount(agent),
              // The run in flight, but only on the card it belongs to — the
              // other one keeps its own numbers rather than borrowing a
              // progress bar for work it isn't doing.
              progress: progress?.agent == agent ? progress : null,
              busyElsewhere: progress != null && progress?.agent != agent,
              onTap: () => onPick(agent),
              onSync: () => onSync(agent),
              onStop: onStop,
            ),
          ),
        const SizedBox(height: 6),
        const WhatComesOver(),
        const Spacer(),
        Align(
          alignment: Alignment.centerLeft,
          child: RefreshButton(onPressed: onRefresh),
        ),
      ],
    );
  }

  /// How many of this tool's sessions a sync would actually bring over — new
  /// ones and ones talked in since. It is the number on the button, because
  /// "Sync 191" and "Sync 3" are very different decisions.
  int _pendingCount(ImportedAgent agent) {
    var count = 0;
    for (final row in rows) {
      if (row.session.agent == agent && row.isActionable) count++;
    }
    return count;
  }

  int _importedCount(ImportedAgent agent) {
    var count = 0;
    for (final row in rows) {
      if (row.session.agent == agent && row.status == ImportStatus.imported) {
        count++;
      }
    }
    return count;
  }
}

/// One tool, as a card you click to see its conversations.
///
/// The two icons with a leader between them are the whole idea in one mark:
/// *that tool's chats, into this app*. Everything else on the card is a count.
class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.agent,
    required this.total,
    required this.imported,
    required this.pending,
    required this.progress,
    required this.busyElsewhere,
    required this.onTap,
    required this.onSync,
    required this.onStop,
  });

  final ImportedAgent agent;
  final int total;
  final int imported;
  final int pending;
  final ImportProgress? progress;

  /// The other card is syncing. Only one run at a time, so this card's own
  /// button is out of action until that one is done.
  final bool busyElsewhere;

  final VoidCallback onTap;
  final VoidCallback onSync;
  final VoidCallback onStop;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  bool _hovered = false;

  /// The tool's own icon, from the same assets the Agents screen uses — so an
  /// agent looks like itself wherever the app draws it.
  String get _asset => switch (widget.agent) {
    ImportedAgent.claude => 'assets/agents/claude_icon.png',
    ImportedAgent.codex => 'assets/agents/codex_icon.png',
  };

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final empty = widget.total == 0;
    return MouseRegion(
      cursor: empty ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: empty ? null : widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
          decoration: BoxDecoration(
            color: _hovered && !empty
                ? AppSurface.hoverFill
                : AppGlass.surfaceFill,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            children: [
              _PairedMark(asset: _asset, dimmed: empty),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Import your ${widget.agent.label} conversations',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: empty
                            ? AppPalette.textSecondary
                            : AppPalette.textPrimary,
                        fontSize: 14,
                        fontWeight: AppFont.medium,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitle(),
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
              if (!empty) ...[
                const SizedBox(width: 12),
                // The card's own action, which is not the card's tap: pressing
                // *Sync* brings everything over, while the card itself opens
                // the list to pick from. Two targets, but the same pair the
                // Archived screen already uses — the row opens the thing, the
                // button does the thing.
                _SyncButton(
                  pending: widget.pending,
                  progress: widget.progress,
                  disabled: widget.busyElsewhere,
                  onSync: widget.onSync,
                  onStop: widget.onStop,
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevronRight300,
                  size: 18,
                  // Full colour under the pointer, like every other affordance
                  // in the app.
                  color: _hovered
                      ? AppPalette.textPrimary
                      : AppPalette.textFaint,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// What is behind the card, in a line: how many conversations, and how many
  /// of them are already here — or, while a sync runs, how far it has got.
  String _subtitle() {
    if (widget.progress case final run?) {
      final failed = run.failed == 0 ? '' : '  ·  ${run.failed} skipped';
      return 'Bringing over ${run.done} of ${run.total}$failed';
    }
    if (widget.total == 0) {
      return 'Nothing from ${widget.agent.label} on this computer yet';
    }
    final conversations = widget.total == 1
        ? '1 conversation'
        : '${widget.total} conversations';
    if (widget.imported == 0) return '$conversations on this computer';
    return '$conversations  ·  ${widget.imported} already imported';
  }
}

/// The card's action: bring everything over, or stop the run that is doing it.
///
/// It names the number rather than saying "Sync all", because the number *is*
/// the decision — 191 conversations is a different thing to agree to than 3,
/// and the second is what this button says every time after the first run.
class _SyncButton extends StatelessWidget {
  const _SyncButton({
    required this.pending,
    required this.progress,
    required this.disabled,
    required this.onSync,
    required this.onStop,
  });

  final int pending;
  final ImportProgress? progress;
  final bool disabled;
  final VoidCallback onSync;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);

    if (progress case final run?) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 92,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: run.fraction,
                minHeight: 4,
                backgroundColor: AppCard.inset,
                valueColor: AlwaysStoppedAnimation(AppPalette.accent),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _CardButton(label: 'Stop', primary: false, onPressed: onStop),
        ],
      );
    }

    // Everything this tool has is already here. Not a disabled button — there
    // is genuinely nothing to do, and a greyed "Sync 0" invites a click that
    // would report nothing happened.
    if (pending == 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.check300, size: 15, color: AppPalette.online),
          const SizedBox(width: 6),
          Text(
            'All here',
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
          ),
        ],
      );
    }

    return _CardButton(
      label: 'Sync $pending',
      primary: true,
      onPressed: disabled ? null : onSync,
    );
  }
}

/// A button on a source card. Primary is the accent fill under white text —
/// the one use that token has.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.primary,
    required this.onPressed,
  });

  final String label;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final enabled = onPressed != null;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: primary ? Colors.white : AppPalette.textPrimary,
        disabledForegroundColor: AppPalette.textFaint,
        backgroundColor: primary
            ? (enabled ? AppPalette.accent : AppCard.inset)
            : AppCard.inset,
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

/// The two icons with a leader between them: that tool, into Grid.
class _PairedMark extends StatelessWidget {
  const _PairedMark({required this.asset, required this.dimmed});

  final String asset;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Tile(child: Image.asset(asset, width: 20, height: 20)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Text(
              '···',
              style: TextStyle(
                color: AppPalette.textFaint,
                fontSize: 13,
                height: 1,
                letterSpacing: 1,
              ),
            ),
          ),
          _Tile(child: Image.asset('assets/brand/grid_logo_bg.png', width: 22)),
        ],
      ),
    );
  }
}

/// One rounded icon tile. Radius 8 — an inset box inside a radius-14 card,
/// never rounder than the box it sits in.
class _Tile extends StatelessWidget {
  const _Tile({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(5), child: child),
    );
  }
}
