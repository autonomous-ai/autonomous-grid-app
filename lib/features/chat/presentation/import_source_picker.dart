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
    required this.onRefresh,
    required this.onPick,
  });

  final List<ImportableSession> rows;
  final VoidCallback onRefresh;
  final ValueChanged<ImportedAgent> onPick;

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
              onTap: () => onPick(agent),
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
    required this.onTap,
  });

  final ImportedAgent agent;
  final int total;
  final int imported;
  final VoidCallback onTap;

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
  /// of them are already here.
  String _subtitle() {
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
