import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/provider_node/logic/provider_run_controller.dart';
import '../../infrastructure/state/models/network_credential.dart';
import 'shell_state.dart';

/// Installs a macOS menu-bar (system tray) icon that reads like the Wi-Fi /
/// Bluetooth menus: a master **Grid** on/off toggle on top, the joined grids as
/// a checkable list in the middle, and **Grid Settings** (opens the app) at the
/// bottom. The toggle mirrors whether an engine is serving — so you can stop
/// sharing or reopen the window without leaving whatever you're doing.
/// No-op off macOS; renders [child] unchanged.
class TrayScope extends ConsumerStatefulWidget {
  const TrayScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayScope> createState() => _TrayScopeState();
}

class _TrayScopeState extends ConsumerState<TrayScope> with TrayListener {
  static const _kToggle = 'toggle';
  static const _kSettings = 'settings';
  static const _gridPrefix = 'grid:';

  // SF Symbol names drawn as tinted icons by our vendored tray_manager patch
  // (packages/tray_manager) — blue for the active grid, grey for the rest, like
  // the macOS Wi-Fi list. The `checked` flag we pass doubles as the tint
  // selector on the native side. Degrades to just the label on macOS < 11.
  // A lightning bolt (matching the in-app grids list) marks each grid row.
  static const _gridSymbol = 'bolt.fill';
  static const _gridsSymbol = 'point.3.connected.trianglepath.dotted';

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
  /// menu: a master **Grid** toggle on top (checked while an engine is serving),
  /// the joined grids as a flat, checkable list in the middle, and **Grid
  /// Settings** (opens the app) at the bottom.
  Future<void> _rebuildMenu() async {
    if (!_ready) return;
    final networks = ref.read(sessionProvider).networks;
    final activeId = ref.read(selectedNetworkProvider)?.networkId;

    await trayManager.setContextMenu(Menu(items: [
      // A Control Center-style switch row rendered natively (see the vendored
      // tray_manager's TrayMenuItemSwitchView); `checked` drives the switch.
      MenuItem(key: _kToggle, type: 'switch', label: 'Grid', checked: _isServing),
      MenuItem.separator(),
      ..._gridItems(networks, activeId),
      MenuItem.separator(),
      MenuItem(key: _kSettings, label: 'Grid Settings'),
    ]));
  }

  /// True while an engine is actively serving a grid — the "Grid is on" signal
  /// the top toggle reflects, mirroring Wi-Fi's connected state.
  bool get _isServing =>
      ref.read(providerRunControllerProvider) is ProviderRunActive;

  /// The grids section: a greyed header (like "Known Networks") followed by one
  /// row per grid. The active grid gets a blue lightning bolt, the rest a grey
  /// one — mirroring the connected vs. available split in the macOS Wi-Fi list,
  /// and matching the in-app grids list. Falls back to a hint when no grid is
  /// joined.
  List<MenuItem> _gridItems(List<NetworkCredential> networks, String? activeId) {
    if (networks.isEmpty) {
      return [MenuItem(key: 'none', label: 'No grids yet', disabled: true)];
    }
    return [
      MenuItem(key: 'header', label: 'Grids', icon: _gridsSymbol, disabled: true),
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

  /// The master toggle. Turning it **off** stops every engine we're serving
  /// (`shutdownServing`) — the honest "leave the grid" action. Turning it **on**
  /// can't happen silently (starting an engine needs a model choice), so we open
  /// the app on the Engines screen where the user picks one — like tapping Wi-Fi
  /// on lands you in its settings. Consumer-only grids have no Engines tab, so we
  /// just reopen the window there.
  Future<void> _toggleGrid() async {
    if (_isServing) {
      await ref.read(providerRunControllerProvider.notifier).shutdownServing();
      return;
    }
    final canManage =
        ref.read(selectedNetworkProvider)?.canManageProvider ?? false;
    if (canManage) {
      ref.read(navSectionProvider.notifier).select(NavSection.provider);
    }
    await _showWindow();
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
    if (key == _kToggle) {
      _toggleGrid();
      return;
    }
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
    // Keep the tray menu in step with the grids list, the active grid, and the
    // serving state the top toggle reflects.
    if (Platform.isMacOS) {
      ref.listen(sessionProvider, (_, __) => _rebuildMenu());
      ref.listen(selectedNetworkProvider, (_, __) => _rebuildMenu());
      ref.listen(providerRunControllerProvider, (_, __) => _rebuildMenu());
    }
    return widget.child;
  }
}
