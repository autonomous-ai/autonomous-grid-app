import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/presentation/chat_history_list.dart';
import '../../../features/code/presentation/code_rail.dart';
import '../../../features/command_palette/presentation/command_palette.dart';
import '../../../features/provider_node/logic/serving_engines_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icon_button.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
import 'sidebar_account.dart';
import 'sidebar_item.dart';

/// The app's left rail: which half of the app you are in, what you can do in
/// it, what you have already done, and who you are signed in as.
///
/// It's the app's only navigation — the sections it lists open in the pane to the
/// right rather than in a dialog, so a first-time user can see the grid and this
/// computer without hunting through a menu.
class AppSidebar extends ConsumerStatefulWidget {
  const AppSidebar({super.key});

  // Wide enough that a chat nested under a project still has room for its title:
  // those rows are indented to line up under the project *name*, which costs the
  // title 38px before it starts. Narrowing that indent closes the gap too, but
  // at the price of a ragged left edge — the rail giving up the space reads
  // better than the list giving up its alignment.
  static const double width = 284;

  @override
  ConsumerState<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends ConsumerState<AppSidebar> {
  void _newChat() {
    ref.read(chatSessionsProvider.notifier).newChat();
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to the app brightness even though the surface moved out to
    // [SidebarFold]: this is where the rail's `const` children are constructed,
    // and a `const` child is not rebuilt by an ancestor's rebuild. Dropping the
    // subscription here would leave anything below that *isn't* watching for
    // itself painted in the palette it first mounted with.
    AppTheme.watch(context);
    final mode = ref.watch(shellModeProvider);

    // Contents only — the fill and the hairline against the pane belong to
    // [SidebarFold], which draws one surface under whichever rail is showing so
    // the fold doesn't stack two translucent fills or strand a second hairline
    // mid-animation.
    //
    // Codex keeps that surface flat and quiet: a near-white fill set apart from
    // the content by a single hairline on its right edge — no gradient, no cast
    // shadow.
    //
    // No backdrop blur either, and it was never doing anything: the rail is the
    // first child of a Row over an opaque `Scaffold(backgroundColor: windowBg)`,
    // so the only thing behind it is one flat colour, and blurring a flat colour
    // gives back the same flat colour. What it did cost was real — a saveLayer
    // and a 6-sigma gaussian over the whole rail on every repaint, and, because
    // a backdrop filter samples what's behind it, the loss of the repaint
    // boundary that would otherwise keep one row's animation to that one row.
    // Selecting a chat re-blurred the entire sidebar, every frame.
    return ClipRect(
      child: SizedBox(
        width: AppSidebar.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Brand(
              onSearch: () => showCommandPalette(context),
              onCollapse: () =>
                  ref.read(sidebarCollapsedProvider.notifier).toggle(),
            ),
            const _ModeSwitch(),
            // The two halves keep their own rails. Nothing is shared between
            // them below this line except the account at the foot — which is
            // the point: they are two places to work, not two filters over
            // one list.
            Expanded(
              child: switch (mode) {
                ShellMode.home => _HomeRail(onNewChat: _newChat),
                ShellMode.code => const CodeRail(),
              },
            ),
            // A full-width hairline sets the account off as the rail's foot,
            // the way Codex separates its signed-in user from the list above.
            const Divider(height: 1, thickness: 1),
            const SizedBox(height: 4),
            const SidebarAccount(),
          ],
        ),
      ),
    );
  }
}

/// Home or Code, at the top of the rail where a person decides what they came
/// to do before they decide which of it.
///
/// A segmented control rather than two nav rows, because the choice is
/// exclusive and changes what every row *under* it means — a nav row that
/// replaced the whole rail would be the only one in the list that did.
///
/// Drawn only when this build has more than one half to offer (see
/// [visibleShellModes]). With Code developer-gated, a shipped build has just
/// Home — and a switch with one segment is a control that answers a question
/// nobody was asked, above a rail it cannot change.
class _ModeSwitch extends ConsumerWidget {
  const _ModeSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = visibleShellModes;
    if (modes.length < 2) return const SizedBox.shrink();
    final mode = ref.watch(shellModeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AppSegmented(
          segments: [
            for (final half in modes)
              SegmentSpec(label: half.label, icon: half.icon),
          ],
          selected: modes.indexOf(mode),
          onChanged: (index) =>
              ref.read(shellModeProvider.notifier).select(modes[index]),
        ),
      ),
    );
  }
}

/// The everyday rail: start a chat, the screens behind it, then every chat you
/// have had.
class _HomeRail extends ConsumerWidget {
  const _HomeRail({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(shellSectionProvider);
    // Read here rather than inside the mark itself: a badge that exists but
    // draws nothing still takes the row's badge gutter, which would leave Model
    // engines' label 8px short of every other row whenever nothing is serving.
    final serving = ref.watch(servingEnginesProvider).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SidebarItem(
                icon: LucideIcons.squarePen300,
                label: 'New chat',
                emphasized: true,
                onTap: onNewChat,
              ),
              // A hair of air between the one thing you *do* (start a chat) and
              // the screens you *go to*, so they read as two groups without
              // needing a divider between them.
              const SizedBox(height: 4),
              for (final target in kSidebarSections)
                SidebarItem(
                  icon: target.thinIcon,
                  label: target.label,
                  selected: section == target,
                  // Only Model engines carries a mark, and only while this
                  // machine is actually serving — it is the one row whose state
                  // changes without the user being on it.
                  badge: serving && target == ShellSection.engines
                      ? const _ServingDot()
                      : null,
                  onTap: () =>
                      ref.read(shellSectionProvider.notifier).select(target),
                ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        // No horizontal padding here: the list owns its own insets so the
        // scrollbar can sit in a gutter at the rail's edge, clear of the rows,
        // instead of overlapping them (Codex keeps this gap).
        const Expanded(child: ChatHistoryList()),
      ],
    );
  }
}

/// The live mark on the Model engines row while this computer is serving.
///
/// The rail is then the only place that says "you are hosting right now"
/// without opening a screen: a host who started an engine and went back to
/// chatting has nothing else on screen telling them it's still running. Mounted
/// only while it's true — see [_HomeRail], which owns that condition.
class _ServingDot extends StatelessWidget {
  const _ServingDot();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Not pulsing, unlike the top bar's: that one marks a live figure the user
    // opened a panel to read, while this sits in a list of rows they scan past.
    return Tooltip(
      message: 'This computer is serving a model',
      child: StatusDot(color: AppPalette.online, size: 6),
    );
  }
}

/// The wordmark row at the top — also the window's drag handle, and on macOS it
/// leaves room for the traffic-light buttons above it.
class _Brand extends StatelessWidget {
  const _Brand({required this.onSearch, required this.onCollapse});

  final VoidCallback onSearch;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final topInset = Platform.isMacOS ? 32.0 : 12.0;
    return DragToMoveArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, topInset, 10, 15),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Grid',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 17,
                  // Semibold, not bold. A wordmark at 17pt already out-ranks
                  // everything in the sidebar by size alone; w700 on top of
                  // that made the app's own name the heaviest ink on screen,
                  // which is a thing to notice once and then stop noticing.
                  fontWeight: AppFont.semibold,
                  // Slightly open, because tight tracking is what makes a short
                  // heavy word read as a solid block rather than as letters.
                  letterSpacing: 0.1,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Search everything  ⌘K',
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              color: AppPalette.textSecondary,
              icon: const Icon(LucideIcons.search300),
              onPressed: onSearch,
            ),
            const SizedBox(width: 2),
            AppIconButton(
              icon: LucideIcons.panelLeft300,
              size: 18,
              tooltip: 'Collapse sidebar  ⌘\\',
              onPressed: onCollapse,
            ),
          ],
        ),
      ),
    );
  }
}
