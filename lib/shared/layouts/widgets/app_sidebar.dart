import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/presentation/chat_history_list.dart';
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
  final _search = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Show / hide the chat search box. Closing it clears the filter, so the full
  /// history is back the moment the box goes away.
  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _search.clear();
        _query = '';
      }
    });
  }

  void _newChat() {
    ref.read(chatSessionsProvider.notifier).newChat();
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  @override
  Widget build(BuildContext context) {
    final section = ref.watch(shellSectionProvider);
    final sending = ref.watch(chatSessionsProvider).sending;

    return Container(
      width: AppSidebar.width,
      decoration: const BoxDecoration(
        color: AppGlass.sidebarFill,
        border: Border(right: BorderSide(color: AppPalette.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(searching: _searching, onToggleSearch: _toggleSearch),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_searching) ...[
                  _SearchField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: 8),
                ],
                SidebarItem(
                  icon: Icons.edit_outlined,
                  label: 'New chat',
                  emphasized: true,
                  enabled: !sending,
                  tooltip: sending ? 'Wait for the reply to finish' : null,
                  onTap: _newChat,
                ),
                for (final target in _navSections)
                  SidebarItem(
                    icon: target.icon,
                    label: target.label,
                    selected: section == target,
                    onTap: () =>
                        ref.read(shellSectionProvider.notifier).select(target),
                  ),
                const SidebarSectionLabel(label: 'Chats'),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ChatHistoryList(query: _query),
            ),
          ),
          const Divider(height: 1),
          const SidebarAccount(),
        ],
      ),
    );
  }

  /// The screens the rail links to. Chat isn't among them: you get there by
  /// starting a chat or opening one from the history below.
  static const _navSections = [
    ShellSection.grids,
    ShellSection.engines,
    ShellSection.guide,
  ];
}

/// The wordmark row at the top — also the window's drag handle, and on macOS it
/// leaves room for the traffic-light buttons above it.
class _Brand extends StatelessWidget {
  const _Brand({required this.searching, required this.onToggleSearch});

  final bool searching;
  final VoidCallback onToggleSearch;

  @override
  Widget build(BuildContext context) {
    final topInset = Platform.isMacOS ? 32.0 : 12.0;
    return DragToMoveArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset, 8, 6),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Grid',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            IconButton(
              tooltip: searching ? 'Close search' : 'Search chats',
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              color: searching
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
              icon: Icon(
                searching ? Icons.close_rounded : Icons.search_rounded,
              ),
              onPressed: onToggleSearch,
            ),
          ],
        ),
      ),
    );
  }
}

/// Filters the chat history by title as you type.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: true,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        hintText: 'Search chats',
        prefixIcon: Icon(Icons.search_rounded, size: 17),
        prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 34),
      ),
    );
  }
}
