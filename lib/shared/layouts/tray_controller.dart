import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/auth/logic/session_controller.dart';
import 'shell_state.dart';

/// Installs a macOS menu-bar (system tray) icon whose menu mirrors the joined
/// grids — so you can switch the active grid and reopen the window without
/// leaving whatever you're doing. No-op off macOS; renders [child] unchanged.
class TrayScope extends ConsumerStatefulWidget {
  const TrayScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayScope> createState() => _TrayScopeState();
}

class _TrayScopeState extends ConsumerState<TrayScope> with TrayListener {
  static const _kOpen = 'open';
  static const _kQuit = 'quit';
  static const _gridPrefix = 'grid:';

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

  /// Rebuilds the context menu from the current grids + active selection.
  Future<void> _rebuildMenu() async {
    if (!_ready) return;
    final networks = ref.read(sessionProvider).networks;
    final activeId = ref.read(selectedNetworkProvider)?.networkId;

    final gridItems = networks.isEmpty
        ? [MenuItem(key: 'none', label: 'No grids yet', disabled: true)]
        : [
            for (final n in networks)
              MenuItem.checkbox(
                key: '$_gridPrefix${n.networkId}',
                label: n.name,
                checked: n.networkId == activeId,
              ),
          ];

    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: _kOpen, label: 'Open Grid'),
      MenuItem.separator(),
      MenuItem.submenu(label: 'Switch grid', submenu: Menu(items: gridItems)),
      MenuItem.separator(),
      MenuItem(key: _kQuit, label: 'Quit Grid'),
    ]));
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _selectGrid(String networkId) {
    final match = ref.read(sessionProvider).byName(networkId);
    if (match == null) return;
    ref.read(selectedNetworkProvider.notifier).select(match);
    ref.read(navSectionProvider.notifier).select(NavSection.networks);
    _showWindow();
  }

  // macOS shows the menu on either click; route both to the context menu.
  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null) return;
    if (key == _kOpen) {
      _showWindow();
      return;
    }
    if (key == _kQuit) {
      // Route through the close handler (preventClose is on) so a running engine
      // is stopped first, instead of destroying the window outright.
      windowManager.close();
      return;
    }
    if (key.startsWith(_gridPrefix)) {
      _selectGrid(key.substring(_gridPrefix.length));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the tray menu in step with the grids list and the active grid.
    if (Platform.isMacOS) {
      ref.listen(sessionProvider, (_, __) => _rebuildMenu());
      ref.listen(selectedNetworkProvider, (_, __) => _rebuildMenu());
    }
    return widget.child;
  }
}
