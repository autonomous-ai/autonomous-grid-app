import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Primary nav sections shown in the left sidebar (Tailscale-style).
enum NavSection {
  networks(Icons.bolt, 'Grids'),
  howToUse(Icons.help_outline_rounded, 'How to use'),
  provider(Icons.dns_outlined, 'Model Engines'),
  chat(Icons.chat_bubble_outline_rounded, 'Chat', devOnly: false),
  overlord(
    Icons.monitor_heart_outlined,
    'Overlord',
    devOnly: true,
    hidden: true,
  ),
  debug(Icons.bug_report_outlined, 'Debug', devOnly: true);

  const NavSection(
    this.icon,
    this.label, {
    this.devOnly = false,
    this.hidden = false,
  });
  final IconData icon;
  final String label;

  /// Only available in dev (debug) builds — hidden in release/production.
  final bool devOnly;

  /// Kept wired (routed + built) but not shown in the sidebar — for sections
  /// still in progress. Flip to re-list it; no other change needed.
  final bool hidden;
}

/// Sections visible in the sidebar. Engines is shown to everyone: installing an
/// engine (Homebrew, llama.cpp, a model) is a local set-up that needs no
/// permission on any grid — only *sharing* it does, and the Engines screen gates
/// that step itself. Hiding the tab was what left consumers with no way to learn
/// how the app works. Dev-only sections (Debug) stay hidden outside debug builds.
final visibleNavSectionsProvider = Provider<List<NavSection>>((ref) {
  return [
    for (final section in NavSection.values)
      if (!section.hidden && (!section.devOnly || kDebugMode)) section,
  ];
});

/// The active sidebar section. Networks is the landing screen.
final navSectionProvider = NotifierProvider<NavSectionNotifier, NavSection>(
  NavSectionNotifier.new,
);

class NavSectionNotifier extends Notifier<NavSection> {
  @override
  NavSection build() => NavSection.networks;

  void select(NavSection section) => state = section;
}
