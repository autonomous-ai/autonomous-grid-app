import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/subscription_model.dart';
import '../../../features/agents/logic/agent_status.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/network/logic/grid_target.dart';
import '../../theme/app_theme.dart';
import '../../widgets/anchored_menu_position.dart';
import '../../widgets/labeled_field.dart';
import '../../widgets/menu_row.dart';
import '../shell_state.dart';

const double _menuWidth = 244.0;

/// What the panel measures, so it can be hung *above* the pill it belongs to.
///
/// Same trap as the account menu directly below this one: the menu is placed by
/// subtracting its own height from the anchor, so a height that disagrees with
/// what draws leaves the panel floating off its button. These are the numbers
/// the rows are actually built from — [MenuRow]'s 32, the note's two lines, a
/// hairline — rather than a figure measured once and left to drift.
const double _rowHeight = kMenuRowHeight;
const double _noteHeight = 45.0;
const double _dividerHeight = 11.0;
const double _panelPadding = 5.0;

/// The menu that changes what answers: which grid this app is on, or — in a
/// developer build — the assistant's own subscription, off every grid.
///
/// Wrapped around whatever [child] the caller draws as its trigger, because the
/// trigger already exists: the status rail has named the active grid since long
/// before it could be changed from there. A pill of its own would have been a
/// second control saying the same word a few pixels above the first.
class GridTargetMenu extends ConsumerStatefulWidget {
  const GridTargetMenu({super.key, required this.child});

  /// What the user presses — the rail's live dot and grid name.
  final Widget child;

  @override
  ConsumerState<GridTargetMenu> createState() => _GridTargetMenuState();
}

class _GridTargetMenuState extends ConsumerState<GridTargetMenu> {
  final _menu = MenuController();
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // The trigger and its menu read colour tokens from a global the element
    // tree can't track, and nothing watched here changes on a theme flip.
    AppTheme.watch(context);
    final networks = ref.watch(sessionProvider.select((s) => s.networks));
    final selected = ref.watch(selectedNetworkProvider);
    // The subscription row is offered on the same two conditions the model
    // picker offers it on, read from the one place that owns them: a developer
    // build, and an assistant installed to answer with (only an agent can run
    // off the grid — see `subscriptionModelOptions`).
    final offerSubscription =
        subscriptionModelIsOffered && ref.watch(anyAgentInstalledProvider);
    final onSubscription = isSubscriptionModelId(
      ref.watch(chatSessionsProvider.select((s) => s.active?.model)),
    );
    final targets = gridTargets(
      networks: networks,
      offerSubscription: offerSubscription,
    );

    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      menuChildren: [
        _MenuContent(
          targets: targets,
          selectedId: selected?.networkId,
          onSubscription: onSubscription,
          onPick: _pick,
          onManage: _openGridSettings,
        ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        label: 'Grid',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggle(controller, targets),
            child: DecoratedBox(
              // A wash rather than a rim: the rail is 26px of furniture, and a
              // bordered pill on it reads as a button dropped onto the window's
              // edge. Lit only under the pointer, or while its menu is open —
              // which is the one moment the trigger has to stay found.
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppControl.radius),
                color: _hovered || controller.isOpen
                    ? AppSurface.hoverFill
                    : Colors.transparent,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the panel above the trigger, sized by what it is about to draw.
  void _toggle(MenuController controller, List<GridTarget> targets) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: Size(_menuWidth, _panelHeight(targets)),
        margin: 8,
        gap: 8,
        preferAbove: true,
      ),
    );
  }

  /// Everything the panel will render, added up — the same pieces
  /// [_MenuContent] draws, in the same order, so the estimate cannot drift from
  /// the panel: the standing note, a hairline, one row per target, then the
  /// hairline and the row that opens Settings.
  double _panelHeight(List<GridTarget> targets) =>
      _panelPadding * 2 +
      _noteHeight +
      _dividerHeight +
      // The line that stands in for an empty list occupies a row too.
      _rowHeight * (targets.isEmpty ? 1 : targets.length) +
      _dividerHeight +
      _rowHeight;

  /// Point the app at [target]: another grid, or the assistant's own account.
  ///
  /// A grid **also hands the open chat back** when it was answering off the
  /// grid, because the menu ticks exactly one row: leaving the chat on the
  /// subscription while ticking a grid would say the next message goes
  /// somewhere it does not.
  void _pick(GridTarget target) {
    _menu.close();
    final chats = ref.read(chatSessionsProvider.notifier);
    if (isSubscriptionTarget(target)) {
      chats.setTargetModel(kSubscriptionModelId);
      return;
    }
    final network = target.network!;
    if (isSubscriptionModelId(ref.read(chatSessionsProvider).active?.model)) {
      chats.clearTargetModel();
    }
    if (network.networkId == ref.read(selectedNetworkProvider)?.networkId) {
      return;
    }
    ref.read(selectedNetworkProvider.notifier).select(network);
  }

  void _openGridSettings() {
    _menu.close();
    ref.read(shellSectionProvider.notifier).select(ShellSection.grids);
  }
}

class _MenuContent extends StatelessWidget {
  const _MenuContent({
    required this.targets,
    required this.selectedId,
    required this.onSubscription,
    required this.onPick,
    required this.onManage,
  });

  final List<GridTarget> targets;
  final String? selectedId;
  final bool onSubscription;
  final ValueChanged<GridTarget> onPick;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _menuWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The reference app says "New agents only. Agents already running keep
        // the provider they started on." Ours cannot: picking here *does* move
        // the open chat's next message. What it leaves behind is what has
        // already started — a turn in flight carries the grid it was dispatched
        // with, and a terminal keeps the one its CLI was spawned with until it
        // is restarted (see `AgentTerminals._setupFor`).
        const _MenuNote(
          'New messages only. Anything already answering keeps the grid it '
          'started on.',
        ),
        const MenuDivider(),
        // Reachable: leaving (or deleting) the last grid mid-session drops the
        // shell to this, and a menu whose middle is simply missing reads as one
        // that failed to load. The row below is where it is fixed.
        if (targets.isEmpty)
          MenuRow(
            label: "You're not on a grid yet",
            width: _menuWidth,
            enabled: false,
            onTap: () {},
          ),
        for (final target in targets)
          MenuRow(
            label: target.label,
            width: _menuWidth,
            // Where the answer comes from, in three words, only where it is
            // not obvious: a grid's name is the whole answer for a grid.
            trailing: isSubscriptionTarget(target)
                ? const _RowNote('on this computer')
                : null,
            selected: isSubscriptionTarget(target)
                ? onSubscription
                : !onSubscription && target.network!.networkId == selectedId,
            onTap: () => onPick(target),
          ),
        const MenuDivider(),
        MenuRow(
          label: 'Grid settings…',
          icon: LucideIcons.settings300,
          width: _menuWidth,
          onTap: onManage,
        ),
      ],
    ),
  );
}

/// The standing note at the head of the panel — what picking here does and does
/// not reach.
///
/// Private until a second menu wants one: [MenuHeading] is the shared slot for
/// a *label* over a run of rows, and a sentence set in it would teach the next
/// reader that headings are where sentences go.
class _MenuNote extends StatelessWidget {
  const _MenuNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kMenuRowGutter + 9, 7, 12, 6),
      child: Text(
        text,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          height: 1.35,
        ),
      ),
    );
  }
}

/// The quiet half-sentence that rides at the end of a row.
class _RowNote extends StatelessWidget {
  const _RowNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      style: TextStyle(color: AppPalette.textFaint, fontSize: 11),
    );
  }
}
