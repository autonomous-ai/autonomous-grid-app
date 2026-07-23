import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The slim bar that rides directly above the chat composer: an icon, one line
/// about the state of the turn, and the ways out of it.
///
/// Every one of these interrupts a user mid-message, so they all wear the same
/// surface and the same rhythm — a plan waiting for approval, files the agent
/// changed, an agent this grid can't run. Three copies of the decoration had
/// already begun to drift apart in radius and padding; this is the one shape.
///
/// Renders nothing by itself when there's nothing to say — the caller decides
/// that, since only it knows what "nothing" means.
class ComposerNoticeBar extends StatelessWidget {
  const ComposerNoticeBar({
    super.key,
    required this.icon,
    required this.label,
    this.actions = const [],
  });

  final IconData icon;

  /// One line, in the user's terms. It sits under a live conversation, so it
  /// gets a line — not a paragraph.
  final String label;

  /// What the user can do about it, left to right, most-final last. Empty when
  /// the bar is purely reporting.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: AppFont.medium),
            ),
          ),
          for (final action in actions) ...[const SizedBox(width: 4), action],
        ],
      ),
    );
  }
}
