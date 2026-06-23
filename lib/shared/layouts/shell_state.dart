import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Primary nav sections shown in the left sidebar (Tailscale-style).
enum NavSection {
  networks(Icons.lan_outlined, 'Networks'),
  playground(Icons.chat_bubble_outline, 'Playground'),
  provider(Icons.podcasts_outlined, 'Provider'),
  models(Icons.memory_outlined, 'Models');

  const NavSection(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// The active sidebar section. Networks is the landing screen.
final navSectionProvider =
    NotifierProvider<NavSectionNotifier, NavSection>(NavSectionNotifier.new);

class NavSectionNotifier extends Notifier<NavSection> {
  @override
  NavSection build() => NavSection.networks;

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
