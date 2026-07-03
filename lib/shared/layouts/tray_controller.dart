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
/// Bluetooth menus: a plain-text share control on top — when an engine is
/// serving, a greyed status line naming the grid it's on plus a **Stop sharing**
/// action; otherwise a single **Share an engine…** action that opens the app to
/// pick a model — then the joined grids as a checkable list, and **Grid
/// Settings** (opens the app) at the bottom. Plain verbs instead of an on/off
/// switch, so a first-timer sees exactly what each item does. No-op off macOS;
/// renders [child] unchanged.
class TrayScope extends ConsumerStatefulWidget {
  const TrayScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayScope> createState() => _TrayScopeState();
}

class _TrayScopeState extends ConsumerState<TrayScope> with TrayListener {
  static const _kShareAction = 'share';
  static const _kStatus = 'status';
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
  /// menu: the plain-text share control on top, the joined grids as a flat,
  /// checkable list in the middle, and **Grid Settings** (opens the app) at the
  /// bottom.
  Future<void> _rebuildMenu() async {
    if (!_ready) return;
    final networks = ref.read(sessionProvider).networks;
    final activeId = ref.read(selectedNetworkProvider)?.networkId;
    final run = ref.read(providerRunControllerProvider);

    await trayManager.setContextMenu(Menu(items: [
      // tạm ẩn đi mai sau mở lại
      // ..._shareItems(run),
      MenuItem.separator(),
      ..._gridItems(networks, activeId),
      MenuItem.separator(),
      MenuItem(key: _kSettings, label: 'Grid Settings'),
    ]));
  }

  /// The top block that replaces the old on/off switch users found confusing.
  /// While an engine is serving it shows a greyed status line naming the grid
  /// (mirroring the in-app "Engine running" / "Starting…" wording) plus a
  /// **Stop sharing** action; otherwise a single **Share an engine…** action
  /// that opens the app to pick a model. Plain verbs — like the macOS Wi-Fi
  /// menu's "Turn Wi-Fi Off" — so it's obvious what each item does.
  List<MenuItem> _shareItems(ProviderRunState run) {
    if (run is! ProviderRunActive) {
      return [MenuItem(key: _kShareAction, label: 'Share an engine…')];
    }
    final status = run.starting
        ? 'Starting on ${_gridLabel(run.grid)}…'
        : 'Engine running on ${_gridLabel(run.grid)}';
    return [
      MenuItem(key: _kStatus, label: status, disabled: true),
      MenuItem(key: _kShareAction, label: 'Stop sharing'),
    ];
  }

  /// Human name for the grid an engine serves. [ProviderRunActive.grid] holds
  /// the network id; resolve it to the grid's display name, falling back to the
  /// id if it isn't in the joined list.
  String _gridLabel(String gridId) =>
      ref.read(sessionProvider).byName(gridId)?.name ?? gridId;

  /// True while an engine is actively serving a grid — drives whether the top
  /// item is **Stop sharing** or **Share an engine…**, and which action it runs.
  bool get _isServing =>
      ref.read(providerRunControllerProvider) is ProviderRunActive;

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

  /// The top share item's action. **Stop sharing** stops every engine we're
  /// serving (`shutdownServing`) — the honest "leave the grid" action.
  /// **Share an engine…** can't start silently (it needs a model choice), so we
  /// open the app on the Engines screen where the user picks one. Consumer-only
  /// grids have no Engines tab, so we just reopen the window there.
  Future<void> _shareOrStop() async {
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
    if (key == _kShareAction) {
      _shareOrStop();
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
