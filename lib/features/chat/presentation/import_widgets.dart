import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';

/// The pieces both halves of Import chats draw — the source picker and the
/// session list — kept here so neither owns what the other needs.

/// What an import does and does not bring with it.
///
/// Said before the button is pressed rather than discovered afterwards: an
/// imported transcript is *not* byte-for-byte what the other tool shows, and a
/// user who finds that out by scrolling one has been misled by omission. Muted
/// and one line, because it is a caveat, not a warning — nothing here goes
/// wrong, some of it simply doesn't come across.
class WhatComesOver extends StatelessWidget {
  const WhatComesOver({super.key});

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
            'Messages come across in full, and so does the work: every command '
            'the assistant ran arrives as a step you can open, with the start '
            "of what it printed. Long output is trimmed, and images stay in "
            'the original.',
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
class RefreshButton extends StatefulWidget {
  const RefreshButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton> {
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

/// Neither tool has left anything on this computer.
class NothingFound extends StatelessWidget {
  const NothingFound({super.key});

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
