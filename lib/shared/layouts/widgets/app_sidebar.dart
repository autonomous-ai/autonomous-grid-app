import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  static const double width = 264;

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
    final section = ref.watch(shellSectionProvider);
    final sending = ref.watch(chatSessionsProvider).sending;

    // Codex keeps the rail flat and quiet: a near-white fill set apart from the
    // content by a single hairline on its right edge — no gradient, no cast
    // shadow, and only a whisper of backdrop blur so a maximised window still
    // reads as one clean surface.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
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
                        icon: Icons.edit_outlined,
                        label: 'New chat',
                        emphasized: true,
                        enabled: !sending,
                        tooltip: sending
                            ? 'Wait for the reply to finish'
                            : null,
                        onTap: _newChat,
                      ),
                      for (final target in kSidebarSections)
                        SidebarItem(
                          icon: target.icon,
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: const ChatHistoryList(),
                  ),
                ),
                const SizedBox(height: 4),
                const SidebarAccount(),
              ],
            ),
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
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Search everything  ⌘K',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: AppPalette.textSecondary,
              icon: const Icon(Icons.search_rounded),
              onPressed: onSearch,
            ),
          ],
        ),
      ),
    );
  }
}
