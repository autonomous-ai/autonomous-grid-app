import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/pill_choice.dart';
import '../../logic/review_base.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_refs.dart';
import '../../logic/review_snapshot.dart';

/// Chooses what the file list is measuring: the work not committed yet, or
/// everything this branch adds on top of another one.
///
/// Two pills rather than a dropdown of four options, because they are two
/// questions and only the second one needs a branch named.
class BasePicker extends ConsumerWidget {
  const BasePicker({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final base = snapshot.base;
    final refs = ref.watch(reviewBaseRefsProvider(snapshot.root)).value ?? [];
    final controller = ref.read(reviewBaseProvider(folder).notifier);
    // What the branch pill would compare against: whichever branch is already
    // chosen, else the one this branch tracks, else the first one Git listed.
    final suggested = switch (base) {
      BranchAgainst(:final ref) => ref,
      UncommittedChanges() => snapshot.upstream ?? refs.firstOrNull,
    };

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        PillChoice(
          label: const Text('Not committed'),
          selected: base is UncommittedChanges,
          onTap: () => controller.show(const UncommittedChanges()),
        ),
        if (suggested != null)
          _BranchPill(
            selected: base is BranchAgainst,
            against: suggested,
            refs: refs,
            onPick: (ref) => controller.show(BranchAgainst(ref)),
          ),
      ],
    );
  }
}

/// The `vs <branch>` pill. Tapping it switches to that comparison; the caret
/// opens the list of branches to measure against.
class _BranchPill extends StatefulWidget {
  const _BranchPill({
    required this.selected,
    required this.against,
    required this.refs,
    required this.onPick,
  });

  final bool selected;
  final String against;
  final List<String> refs;
  final ValueChanged<String> onPick;

  @override
  State<_BranchPill> createState() => _BranchPillState();
}

class _BranchPillState extends State<_BranchPill> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 4),
      style: appMenuStyle(),
      menuChildren: [
        for (final ref in widget.refs)
          MenuItemButton(
            onPressed: () => widget.onPick(ref),
            leadingIcon: Icon(
              ref == widget.against ? LucideIcons.check : LucideIcons.gitBranch,
              size: 14,
              color: ref == widget.against
                  ? AppPalette.accentOnSurface
                  : AppPalette.textSecondary,
            ),
            child: Text(ref, style: const TextStyle(fontSize: 13)),
          ),
      ],
      builder: (context, controller, _) => PillChoice(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                'vs ${widget.against}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.chevronDown,
              size: 13,
              color: widget.selected ? Colors.white : AppPalette.textSecondary,
            ),
          ],
        ),
        selected: widget.selected,
        // Already on this comparison? The pill's job becomes changing which
        // branch. Otherwise it switches to it first — one tap, not two.
        onTap: () {
          if (!widget.selected) {
            widget.onPick(widget.against);
            return;
          }
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
    );
  }
}
