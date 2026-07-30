import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/presentation/chat_history_list.dart';
import '../../../features/command_palette/presentation/command_palette.dart';
import '../../theme/app_theme.dart';
import '../shell_state.dart';
import 'sidebar_account.dart';
import 'sidebar_item.dart';

/// The app's left rail: what you can do (start a chat, and the three screens
/// behind it), then every chat you've had, then who you're signed in as.
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
    // Subscribe to the app brightness so the rail re-colours the instant the
    // theme flips. Without this the sidebar is `const`-mounted and reads its
    // colours from a global the element tree can't see, so it only repainted
    // when some *other* change (clicking a row) happened to rebuild it.
    AppTheme.watch(context);
    final section = ref.watch(shellSectionProvider);

    // Codex keeps the rail flat and quiet: a near-white fill set apart from the
    // content by a single hairline on its right edge — no gradient, no cast
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.sidebarFill,
          border: Border(right: BorderSide(color: AppPalette.divider)),
        ),
        child: SizedBox(
          width: AppSidebar.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Brand(onSearch: () => showCommandPalette(context)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SidebarItem(
                      icon: LucideIcons.squarePen300,
                      label: 'New chat',
                      emphasized: true,
                      onTap: _newChat,
                    ),
                    // A hair of air between the one thing you *do* (start a
                    // chat) and the screens you *go to*, so they read as two
                    // groups without needing a divider between them.
                    const SizedBox(height: 4),
                    for (final target in kSidebarSections)
                      SidebarItem(
                        icon: target.thinIcon,
                        label: target.label,
                        selected: section == target,
                        onTap: () => ref
                            .read(shellSectionProvider.notifier)
                            .select(target),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              // No horizontal padding here: the list owns its own insets so
              // the scrollbar can sit in a gutter at the rail's edge, clear of
              // the rows, instead of overlapping them (Codex keeps this gap).
              const Expanded(child: ChatHistoryList()),
              // A full-width hairline sets the account off as the rail's foot,
              // the way Codex separates its signed-in user from the list above.
              const Divider(height: 1, thickness: 1),
              const SizedBox(height: 4),
              const SidebarAccount(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The wordmark row at the top — also the window's drag handle, and on macOS it
/// leaves room for the traffic-light buttons above it.
class _Brand extends StatelessWidget {
  const _Brand({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final topInset = Platform.isMacOS ? 32.0 : 12.0;
    return DragToMoveArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, topInset, 12, 15),
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
          ],
        ),
      ),
    );
  }
}
