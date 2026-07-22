import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/chat/logic/chat_sessions_controller.dart';
import 'shell_state.dart';

/// Installs a macOS menu-bar (system tray) icon that reads like a Codex / ChatGPT
/// menu: a few quick actions rather than a directory. It lists the recent chats,
/// then "New chat", "Open Grid" and "Quit Grid" — so the menu bar is a shortcut
/// back into a conversation, not a grid switcher (grids live behind Settings).
/// No-op off macOS; renders [child] unchanged.
class TrayScope extends ConsumerStatefulWidget {
  const TrayScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayScope> createState() => _TrayScopeState();
}

class _TrayScopeState extends ConsumerState<TrayScope> with TrayListener {
  static const _chatPrefix = 'chat:';
  static const _maxRecent = 5;

  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS) return;
    trayManager.addListener(this);
    _initTray();
  }

  @override
  void dispose() {
    if (Platform.isMacOS) trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    // Tolerate the plugin being absent (e.g. a stale build that predates it) so
    // the app runs fine without the tray instead of throwing on startup.
    try {
      await trayManager.setIcon('assets/tray/tray_icon.png');
      await trayManager.setToolTip('Grid');
      if (!mounted) return;
      _ready = true;
      await _rebuildMenu();
    } on Object catch (e) {
      debugPrint('Tray unavailable, skipping menu-bar icon: $e');
    }
  }

  /// Rebuilds the context menu so its "Recent" list stays in step with the chats
  /// the user has (new ones appear, the agent's renames land).
  Future<void> _rebuildMenu() async {
    if (!_ready) return;
    await trayManager.setContextMenu(Menu(items: _actionItems(_recentChats())));
  }

  /// The newest few chats, as (id, label) pairs — the menu only needs a title to
  /// show and an id to reopen, so it takes just those rather than the whole
  /// conversation.
  List<({String id, String label})> _recentChats() {
    // Live only: "recent chats" in the menu bar means the ones still in play,
    // not something the user filed away.
    final conversations = [...ref.read(chatSessionsProvider).live]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [
      for (final c in conversations.take(_maxRecent))
        (id: c.id, label: _trim(c.title)),
    ];
  }

  /// The quick actions, Codex-style: recent chats (when there are any), then the
  /// three the menu bar is really for — start a chat, bring the window forward,
  /// quit.
  List<MenuItem> _actionItems(List<({String id, String label})> recent) {
    return [
      if (recent.isNotEmpty) ...[
        MenuItem(key: 'recent', label: 'Recent', disabled: true),
        for (final chat in recent)
          MenuItem(key: '$_chatPrefix${chat.id}', label: chat.label),
        MenuItem.separator(),
      ],
      MenuItem(key: 'new', label: 'New chat'),
      MenuItem(key: 'open', label: 'Open Grid'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Grid'),
    ];
  }

  /// Keep a menu row to one line — a long chat title would stretch the menu out.
  static String _trim(String title) {
    final clean = title.trim();
    if (clean.isEmpty) return 'Untitled chat';
    return clean.length <= 44 ? clean : '${clean.substring(0, 43)}…';
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Open a saved chat: switch the shell to Chat, select it, raise the window.
  void _openChat(String id) {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    ref.read(chatSessionsProvider.notifier).select(id);
    _showWindow();
  }

  /// Start a fresh chat and bring the window forward on it.
  void _newChat() {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    ref.read(chatSessionsProvider.notifier).newChat();
    _showWindow();
  }

  /// Quit via the window's close path so the shared teardown
  /// ([WindowLifecycleScope.onWindowClose], armed by `setPreventClose`) stops any
  /// serving engine before the process exits — the same as the window's own close
  /// button, not a raw kill that would strand `llama-server`.
  Future<void> _quit() => windowManager.close();

  // macOS shows the menu on either click; route both to the context menu.
  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null) return;
    if (key.startsWith(_chatPrefix)) {
      _openChat(key.substring(_chatPrefix.length));
      return;
    }
    switch (key) {
      case 'new':
        _newChat();
      case 'open':
        _showWindow();
      case 'quit':
        _quit();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Refresh the "Recent" list as chats are added or renamed.
    if (Platform.isMacOS) {
      ref.listen(chatSessionsProvider, (_, _) => _rebuildMenu());
    }
    return widget.child;
  }
}
