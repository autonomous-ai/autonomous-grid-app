import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../infrastructure/state/models/network_credential.dart';

/// Installs a macOS menu-bar (system tray) icon that reads like the Wi-Fi /
/// Bluetooth menus: the joined grids as a checkable list — the active grid
/// marked with a gold lightning bolt, the rest grey — with **Grid Settings**
/// (opens the app) at the bottom. Clicking a grid selects it and shows the
/// window. No-op off macOS; renders [child] unchanged.
class TrayScope extends ConsumerStatefulWidget {
  const TrayScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayScope> createState() => _TrayScopeState();
}

class _TrayScopeState extends ConsumerState<TrayScope> with TrayListener {
  static const _kSettings = 'settings';
  static const _gridPrefix = 'grid:';

  // SF Symbol names drawn as tinted icons by our vendored tray_manager patch
  // (packages/tray_manager) — brand gold for the active grid, grey for the rest,
  // like the macOS Wi-Fi list. The `checked` flag we pass doubles as the tint
  // selector on the native side. Degrades to just the label on macOS < 11.
  // A lightning bolt (matching the in-app grids list) marks each grid row.
  static const _gridSymbol = 'bolt.fill';

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

  /// Rebuilds the context menu so it reads like the macOS Wi-Fi / Bluetooth
  /// menu: the joined grids as a flat, checkable list, with **Grid Settings**
  /// (opens the app) at the bottom.
  Future<void> _rebuildMenu() async {
    if (!_ready) return;
    final networks = ref.read(sessionProvider).networks;
    final activeId = ref.read(selectedNetworkProvider)?.networkId;

    await trayManager.setContextMenu(Menu(items: [
      ..._gridItems(networks, activeId),
      MenuItem.separator(),
      MenuItem(key: _kSettings, label: 'Grid Settings'),
    ]));
  }

  /// The grids section: one row per grid. The active grid gets a gold lightning
  /// bolt, the rest a grey one — mirroring the connected vs. available split in
  /// the macOS Wi-Fi list, and matching the in-app grids list. Falls back to a
  /// hint when no grid is joined.
  List<MenuItem> _gridItems(List<NetworkCredential> networks, String? activeId) {
    if (networks.isEmpty) {
      return [MenuItem(key: 'none', label: 'No grids yet', disabled: true)];
    }
    return [
      for (final n in networks)
        MenuItem(
          key: '$_gridPrefix${n.networkId}',
          label: n.name,
          icon: _gridSymbol,
          checked: n.networkId == activeId,
        ),
    ];
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _selectGrid(String networkId) {
    final match = ref.read(sessionProvider).byName(networkId);
    if (match == null) return;
    ref.read(selectedNetworkProvider.notifier).select(match);
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
    if (key == _kSettings) {
      _showWindow();
      return;
    }
    if (key.startsWith(_gridPrefix)) {
      _selectGrid(key.substring(_gridPrefix.length));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the tray menu in step with the grids list and which grid is active.
    if (Platform.isMacOS) {
      ref.listen(sessionProvider, (_, _) => _rebuildMenu());
      ref.listen(selectedNetworkProvider, (_, _) => _rebuildMenu());
    }
    return widget.child;
  }
}
