import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The screens inside the Settings dialog — the infrastructure the app used to
/// show in a sidebar. The app itself is just chat now; these open from the
/// account menu, each on its own tab. Grids first: it's the one a returning
/// admin reaches for.
enum SettingsTab {
  grids(Icons.bolt, 'Grids'),
  engines(Icons.dns_outlined, 'Engines'),
  howToUse(Icons.help_outline_rounded, 'How to use');

  const SettingsTab(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// The active Settings tab. Set before opening the dialog (so it lands on the
/// right screen), and switched by deep-links from within it — a card that says
/// "Set up engine" flips this to [SettingsTab.engines] rather than stacking a
/// second dialog.
final settingsTabProvider = NotifierProvider<SettingsTabNotifier, SettingsTab>(
  SettingsTabNotifier.new,
);

class SettingsTabNotifier extends Notifier<SettingsTab> {
  @override
  SettingsTab build() => SettingsTab.grids;

  void select(SettingsTab tab) => state = tab;
}
