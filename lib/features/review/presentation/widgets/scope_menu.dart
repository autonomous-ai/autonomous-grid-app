import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_refs.dart';
import '../../logic/review_scope.dart';
import '../../logic/review_snapshot.dart';
import '../../../../shared/widgets/menu_row.dart';
import '../../../../shared/widgets/toolbar_pill.dart';

/// The one control that says what the surface is showing — the button in the
/// toolbar and the menu it opens.
///
/// One menu rather than a row of pills, because these are six answers to a
/// single question ("which changes?") and only two of them need something else
/// named. The two that do get a submenu instead of a second control in the
/// toolbar.
class ScopeMenu extends ConsumerWidget {
  const ScopeMenu({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;

  /// The folder being reviewed — what the choice is remembered against.
  final String folder;

  /// Wide enough for `origin/feature/some-longer-name` before it ellipsizes,
  /// and for the second line under "Last turn" to be a sentence rather than a
  /// sentence with its end cut off. Still narrow enough to sit under a 420px
  /// panel without covering it.
  static const double width = 300;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return _Anchor(snapshot: snapshot, folder: folder);
  }
}

class _Anchor extends ConsumerStatefulWidget {
  const _Anchor({required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  @override
  ConsumerState<_Anchor> createState() => _AnchorState();
}

class _AnchorState extends ConsumerState<_Anchor> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final scope = widget.snapshot.scope;
    final lastTurn = ref.watch(reviewLastTurnPathsProvider);

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      style: appMenuStyle(),
      menuChildren: [
        MenuRow(
          label: 'Last turn',
          detail: lastTurn.isEmpty
              ? "The assistant hasn't changed a file yet"
              : '${lastTurn.length} file${lastTurn.length == 1 ? '' : 's'} '
                    'the assistant just changed',
          icon: LucideIcons.sparkles,
          width: ScopeMenu.width,
          enabled: lastTurn.isNotEmpty,
          selected: scope is LastTurnChanges,
          onTap: () => _pick(const LastTurnChanges()),
        ),
        MenuRow(
          label: 'Uncommitted',
          icon: LucideIcons.filePen,
          width: ScopeMenu.width,
          selected: scope is UncommittedChanges,
          onTap: () => _pick(const UncommittedChanges()),
        ),
        MenuRow(
          label: 'Unstaged',
          icon: LucideIcons.circleDashed,
          width: ScopeMenu.width,
          selected: scope is UnstagedChanges,
          onTap: () => _pick(const UnstagedChanges()),
        ),
        MenuRow(
          label: 'Staged',
          icon: LucideIcons.circleCheck,
          width: ScopeMenu.width,
          selected: scope is StagedChanges,
          onTap: () => _pick(const StagedChanges()),
        ),
        const MenuDivider(),
        _CommittedSubmenu(
          root: widget.snapshot.root,
          scope: scope,
          onPick: _pick,
        ),
        _BranchSubmenu(
          root: widget.snapshot.root,
          current: widget.snapshot.branch,
          upstream: widget.snapshot.upstream,
          scope: scope,
          onPick: _pick,
        ),
      ],
      builder: (context, controller, _) =>
          _ScopeButton(scope: scope, controller: controller),
    );
  }

  void _pick(ReviewScope scope) {
    _menu.close();
    ref.read(reviewScopeProvider(widget.folder).notifier).show(scope);
  }
}

/// The toolbar button: what is being shown, and a caret that says there is more.
///
/// The same [ToolbarPill] the commit control is built from, untinted — the two
/// ends of the toolbar were drawn twice and had already drifted a pixel of
/// padding apart.
class _ScopeButton extends StatelessWidget {
  const _ScopeButton({required this.scope, required this.controller});

  final ReviewScope scope;
  final MenuController controller;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final open = controller.isOpen;
    return ToolbarPill(
      active: open,
      onTap: () => open ? controller.close() : controller.open(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              scope.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          AnimatedRotation(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            turns: open ? 0.5 : 0,
            child: Icon(
              LucideIcons.chevronDown,
              size: 13,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Committed ›" — the recent commits, read when the row is opened.
class _CommittedSubmenu extends ConsumerWidget {
  const _CommittedSubmenu({
    required this.root,
    required this.scope,
    required this.onPick,
  });

  final String root;
  final ReviewScope scope;
  final ValueChanged<ReviewScope> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commits = ref.watch(reviewCommitsProvider(root)).value ?? const [];
    // A local, so `is` promotes it — a field can't be promoted, and the row
    // needs to compare the chosen commit with each one it draws.
    final chosen = scope;
    return _Submenu(
      label: 'Committed',
      icon: LucideIcons.gitCommitHorizontal,
      selected: scope is CommittedChange,
      children: [
        if (commits.isEmpty)
          const _EmptySubmenu('Nothing has been committed here yet.')
        else
          for (final commit in commits)
            MenuRow(
              label: commit.subject,
              detail: '${commit.shortSha} · ${commit.author} · ${commit.when}',
              icon: LucideIcons.gitCommitHorizontal,
              width: ScopeMenu.width,
              selected:
                  chosen is CommittedChange && chosen.commit.sha == commit.sha,
              onTap: () => onPick(CommittedChange(commit)),
            ),
      ],
    );
  }
}

/// "Branch ›" — every branch this change could be measured against.
class _BranchSubmenu extends ConsumerWidget {
  const _BranchSubmenu({
    required this.root,
    required this.current,
    required this.upstream,
    required this.scope,
    required this.onPick,
  });

  final String root;

  /// The branch the repository is on — never offered to compare with itself.
  final String current;

  final String? upstream;
  final ReviewScope scope;
  final ValueChanged<ReviewScope> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refs = ref.watch(reviewBaseRefsProvider(root)).value ?? const [];
    final offered = [
      for (final ref in refs)
        if (ref.name != current) ref,
    ];
    final chosen = scope;
    return _Submenu(
      label: 'Branch',
      icon: LucideIcons.gitBranch,
      selected: scope is BranchAgainst,
      children: [
        if (offered.isEmpty)
          const _EmptySubmenu('This repository has no other branch yet.')
        else
          for (final branch in offered)
            MenuRow(
              label: branch.name,
              detail: branch.name == upstream
                  ? 'What this branch tracks'
                  : branch.remote
                  ? 'Shared with others'
                  : 'On this computer',
              icon: LucideIcons.gitBranch,
              width: ScopeMenu.width,
              selected: chosen is BranchAgainst && chosen.ref == branch.name,
              onTap: () => onPick(BranchAgainst(branch.name)),
            ),
      ],
    );
  }
}

/// The gap Material reserves at the end of a submenu row, worked out the way
/// `_MenuItemLabel` does — its constants are private, so the formula is
/// mirrored rather than the number copied.
///
/// It has to be accounted for because it cannot be removed: the space is padding
/// around `submenuIcon`, and a *null* `submenuIcon` doesn't mean "none" — it
/// falls back to Material's own solid black triangle. So the glyph is emptied
/// and the row's body made narrower by exactly this much, which is what keeps
/// every row in the menu the same width.
double _submenuTrailingGap(BuildContext context) =>
    math.max(4, 12 + Theme.of(context).visualDensity.horizontal * 2);

/// A row that opens more rows.
///
/// [SubmenuButton] rather than a second [MenuAnchor]: it is what places the
/// panel beside its parent, keeps it open while the pointer travels there, and
/// closes the whole stack on a pick. Its own chrome is stripped back to
/// nothing so the row inside reads as the app's, not Material's.
class _Submenu extends StatelessWidget {
  const _Submenu({
    required this.label,
    required this.icon,
    required this.selected,
    required this.children,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final gap = _submenuTrailingGap(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kMenuRowGutter),
      child: SubmenuButton(
        alignmentOffset: const Offset(6, -6),
        menuStyle: appMenuStyle(),
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          // Material pads every button out to a 48px tap target, which left
          // these two rows visibly taller than the four above them.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: WidgetStatePropertyAll(
            selected ? AppSurface.accentWash : Colors.transparent,
          ),
          overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
          splashFactory: NoSplash.splashFactory,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: kMenuRowRadius),
          ),
        ),
        // The app's chevron in the slot Material reserves, rather than null —
        // which is what asks for its own solid triangle, and left two arrows on
        // the row with the second hanging outside the panel.
        submenuIcon: const WidgetStatePropertyAll(MenuRowChevron()),
        menuChildren: children,
        child: MenuRowBody(
          label: label,
          icon: icon,
          // Narrower by exactly what the chevron and Material's gap take, so
          // the row measures the same as every other one and its glyph lands in
          // the same column as their check.
          width:
              ScopeMenu.width - kMenuRowGutter * 2 - gap - MenuRowChevron.width,
          selected: selected,
          tint: selected
              ? AppPalette.accentOnSurface
              : AppPalette.textSecondary,
        ),
      ),
    );
  }
}

/// A submenu with nothing in it — says why, rather than opening onto a void.
class _EmptySubmenu extends StatelessWidget {
  const _EmptySubmenu(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      width: ScopeMenu.width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kMenuRowGutter + 9, 6, 12, 10),
        child: Text(
          message,
          style: TextStyle(
            fontSize: 12,
            height: 1.35,
            color: AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}
