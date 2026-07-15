import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The screens the app can show in its main pane.
///
/// Two groups, and the split is deliberate: the sidebar lists what you *do* every
/// day (chat, and the things that shape how the agent answers), while the
/// plumbing you set up once — which grids you can talk to, what this computer
/// runs, Telegram, how to point other apps at it — lives behind Settings.
///
/// Icons are Lucide throughout, so the nav, the settings rail and the sidebar all
/// speak one visual language.
enum ShellSection {
  chat(LucideIcons.messageSquare, 'Chat'),
  scheduled(LucideIcons.calendarClock, 'Scheduled'),
  agents(LucideIcons.bot, 'Agents'),
  plugins(LucideIcons.puzzle, 'Plugins'),
  projects(LucideIcons.folderOpen, 'Projects'),
  telegram(LucideIcons.send, 'Telegram'),
  grids(LucideIcons.zap, 'Grids'),
  engines(LucideIcons.server, 'This computer'),
  guide(LucideIcons.circleHelp, 'How to use'),
  debug(LucideIcons.terminal, 'Debug');

  const ShellSection(this.icon, this.label);

  final IconData icon;
  final String label;

  /// True for the screens Settings owns — they're drawn full-screen with the
  /// settings nav beside them, not inside the app shell.
  bool get isSettings => kSettingsSections.contains(this);
}

/// What the sidebar's nav lists, in order.
///
/// Chat isn't among them (you get there by starting a chat or opening one), and
/// neither is Projects — your projects *are* the rail below, each holding its
/// chats; this section is the screen that manages them, opened from that header.
/// Agents before Plugins: which assistant does the work, then the tools you give
/// it.
const kSidebarSections = [
  ShellSection.scheduled,
  ShellSection.agents,
  ShellSection.plugins,
];

/// What Settings lists, in order — the screens you set up once.
///
/// Grids leads: it's the one you come back to, and the only one you can't use the
/// app without. The guide, then Debug, sit at the bottom: you read one once, and
/// the other only when something has gone wrong.
const kSettingsSections = [
  ShellSection.grids,
  ShellSection.engines,
  ShellSection.telegram,
  ShellSection.guide,
  ShellSection.debug,
];

/// Where Settings opens when the user asked for Settings rather than for one
/// screen inside it (the account menu, ⌘K) — the first thing it lists.
const kDefaultSettingsSection = ShellSection.grids;

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

  /// Switch to [section], remembering where we came from if we're entering
  /// Settings — so "Back to app" can return to the work screen rather than
  /// always dumping the user in Chat.
  void select(ShellSection section) {
    if (section.isSettings && !state.isSettings) previous = state;
    state = section;
  }

  /// The work section the user was on before opening Settings — Chat by
  /// default, or whichever of Grids/Activity/etc. they were looking at.
  ShellSection previous = ShellSection.chat;
}
