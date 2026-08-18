import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/app_theme.dart';
import '../office_entry.dart';
import '../shell_state.dart';
import 'sidebar_item.dart';

/// The **Office** row and the apps under it.
///
/// A group rather than a nav row, because Office is not a screen: there is
/// nothing to show for "Office" itself, only the document apps inside it. So the
/// row opens instead of navigating — the same gesture a project in the rail below
/// already answers to, so the sidebar has one way of holding rows inside a row.
///
/// It opens itself whenever the section on screen is one of its own
/// ([kOfficeSections]), so the door the user came through stays where they can
/// reach it — arriving in Docs from ⌘K with the group collapsed would hide it.
///
/// **Its rows are actions, not places, so none of them is ever marked.** Docs
/// works the way New chat above it does: pressing it clears the desk and starts
/// a conversation for whatever document comes next, and pressing it again does
/// that again. What marks where the user *is* is the chat's own row under
/// Chats — one document, one conversation, one lit row. Marking this row too
/// would light the rail twice for one screen and would promise that pressing it
/// returns you to what is already open, which is the one thing it does not do.
class SidebarOfficeGroup extends ConsumerStatefulWidget {
  const SidebarOfficeGroup({super.key});

  @override
  ConsumerState<SidebarOfficeGroup> createState() => _SidebarOfficeGroupState();
}

class _SidebarOfficeGroupState extends ConsumerState<SidebarOfficeGroup> {
  /// Whether the user opened it by hand. The group can also be open because it
  /// holds the section on screen — see [_isOpen].
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    final section = ref.watch(shellSectionProvider);
    final rows = [
      for (final target in kOfficeSections)
        if (target.isVisibleForBuild) target,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    final holdsSection = rows.contains(section);
    final open = _opened || holdsSection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarItem(
          icon: LucideIcons.briefcase300,
          label: 'Office',
          // The row's state, not an action — so it stays put instead of
          // appearing under the pointer like a delete button.
          trailingAlwaysVisible: true,
          trailingWidth: 20,
          trailing: _Chevron(open: open),
          // Toggles what the user asked for — but while one of its rows *is* the
          // screen on display the group stays open regardless: folding the door
          // away while the user is standing in the room leaves them nothing to
          // press to start the next document.
          onTap: () => setState(() => _opened = !open),
        ),
        if (open)
          for (final target in rows)
            Padding(
              // Lines the app's name up under "Office" — the row's own 10px
              // inset plus an 18px glyph plus a 10px gap is 38px, and this is
              // the same 28px the rail's chats sit at under a project name. One
              // left edge for everything nested in this rail.
              padding: const EdgeInsets.only(left: 28),
              child: SidebarItem(
                label: target.label,
                // Unmarked on purpose — see the class doc.
                //
                // Not a plain `select` either: entering Docs clears the desk
                // and starts a conversation for whatever document comes next.
                // See [enterOfficeApp].
                onTap: () => unawaited(enterOfficeApp(context, ref, target)),
              ),
            ),
      ],
    );
  }
}

/// The mark that says the row holds more rows, pointing at where they are.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedRotation(
      turns: open ? 0.25 : 0,
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      child: Icon(
        LucideIcons.chevronRight300,
        size: 14,
        color: AppPalette.textFaint,
      ),
    );
  }
}
