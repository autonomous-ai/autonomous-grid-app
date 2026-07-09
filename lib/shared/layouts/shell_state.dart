import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';

/// Primary nav sections shown in the left sidebar (Tailscale-style).
enum NavSection {
  networks(Icons.bolt, 'Grids'),
  howToUse(Icons.help_outline_rounded, 'How to use'),
  provider(Icons.dns_outlined, 'Engines', providerOnly: true),
  chat(Icons.chat_bubble_outline_rounded, 'Chat', devOnly: true),
  overlord(
    Icons.monitor_heart_outlined,
    'Overlord',
    devOnly: true,
    hidden: false,
  ),
  debug(Icons.bug_report_outlined, 'Debug', devOnly: true);

  const NavSection(
    this.icon,
    this.label, {
    this.providerOnly = false,
    this.devOnly = false,
    this.hidden = false,
  });
  final IconData icon;
  final String label;

  /// Only available when the selected network grants the provider scope.
  final bool providerOnly;

  /// Only available in dev (debug) builds — hidden in release/production.
  final bool devOnly;

  /// Kept wired (routed + built) but not shown in the sidebar — for sections
  /// still in progress. Flip to re-list it; no other change needed.
  final bool hidden;
}

/// Sections visible for the currently selected network. Engines is hidden on
/// consumer-only networks; admins and providers see it. Dev-only sections
/// (Debug) are hidden outside debug builds.
final visibleNavSectionsProvider = Provider<List<NavSection>>((ref) {
  final canManage =
      ref.watch(selectedNetworkProvider)?.canManageProvider ?? false;
  return [
    for (final section in NavSection.values)
      if (!section.hidden &&
          (!section.providerOnly || canManage) &&
          (!section.devOnly || kDebugMode))
        section,
  ];
});

/// The active sidebar section. Networks is the landing screen.
final navSectionProvider = NotifierProvider<NavSectionNotifier, NavSection>(
  NavSectionNotifier.new,
);

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
