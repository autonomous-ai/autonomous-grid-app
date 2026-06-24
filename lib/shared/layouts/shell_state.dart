import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';

/// Primary nav sections shown in the left sidebar (Tailscale-style).
enum NavSection {
  networks(Icons.lan_outlined, 'Networks'),
  playground(Icons.chat_bubble_outline, 'Playground'),
  provider(Icons.podcasts_outlined, 'Provider', providerOnly: true),
  models(Icons.memory_outlined, 'Models', providerOnly: true);

  const NavSection(this.icon, this.label, {this.providerOnly = false});
  final IconData icon;
  final String label;

  /// Only available when the selected network grants the provider scope.
  final bool providerOnly;
}

/// Sections visible for the currently selected network. Provider/Models are
/// hidden on consumer-only networks; admins and providers see them.
final visibleNavSectionsProvider = Provider<List<NavSection>>((ref) {
  final canManage =
      ref.watch(selectedNetworkProvider)?.canManageProvider ?? false;
  return [
    for (final section in NavSection.values)
      if (!section.providerOnly || canManage) section,
  ];
});

/// The active sidebar section. Networks is the landing screen.
final navSectionProvider =
    NotifierProvider<NavSectionNotifier, NavSection>(NavSectionNotifier.new);

class NavSectionNotifier extends Notifier<NavSection> {
  @override
  NavSection build() {
    // Switching to a consumer network hides the provider-only sections — don't
    // strand the user on a now-invisible tab; fall back to Networks.
    ref.listen(selectedNetworkProvider, (_, next) {
      final canManage = next?.canManageProvider ?? false;
      if (state.providerOnly && !canManage) state = NavSection.networks;
    });
    return NavSection.networks;
  }

  void select(NavSection section) => state = section;
}

/// The top-bar connection toggle. Cosmetic mock of Tailscale's "Connected"
/// switch — flips the header status + dims the detail when off. Defaults on.
final connectedProvider =
    NotifierProvider<ConnectedNotifier, bool>(ConnectedNotifier.new);

class ConnectedNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
  void set(bool value) => state = value;
}
