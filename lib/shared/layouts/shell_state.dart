import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The screens the app can show in its main pane.
///
/// Two groups, and the split is deliberate: the sidebar lists what you *do* every
/// day (chat, and the three things that shape how the agent answers), while the
/// account menu holds the plumbing you set up once (which grids you can talk to,
/// what this computer runs, how to point other apps at it).
enum ShellSection {
  chat(Icons.chat_bubble_outline_rounded, 'Chat'),
  scheduled(Icons.schedule_rounded, 'Scheduled'),
  plugins(Icons.extension_outlined, 'Plugins'),
  projects(Icons.folder_open_rounded, 'Projects'),
  grids(Icons.bolt, 'Grids'),
  engines(Icons.dns_outlined, 'This computer'),
  guide(Icons.help_outline_rounded, 'How to use');

  const ShellSection(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// What the sidebar lists, in order. Chat isn't among them: you get there by
/// starting a chat or opening one from the history below.
const kSidebarSections = [
  ShellSection.scheduled,
  ShellSection.plugins,
  ShellSection.projects,
];

/// What the account menu lists — the setup screens, out of the daily path.
const kAccountSections = [
  ShellSection.grids,
  ShellSection.engines,
  ShellSection.guide,
];

/// The open section. Chat on launch — that's what the app is for.
///
/// Also the target of in-app deep links: a card that says "Set up engine" flips
/// this to [ShellSection.engines] instead of opening a second window on top.
final shellSectionProvider =
    NotifierProvider<ShellSectionNotifier, ShellSection>(
      ShellSectionNotifier.new,
    );

class ShellSectionNotifier extends Notifier<ShellSection> {
  @override
  ShellSection build() => ShellSection.chat;

  void select(ShellSection section) => state = section;
}
