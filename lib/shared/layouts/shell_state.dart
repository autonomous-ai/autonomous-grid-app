import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_environment.dart';

/// The screens the app can show in its main pane.
///
/// Two groups, and the split is deliberate: the sidebar lists what you *do* every
/// day (chat, and the things that shape how the agent answers), while the
/// plumbing you set up once — which grids you can talk to, what this computer
/// runs, the chat apps it answers from, how to point other apps at it — lives
/// behind Settings.
///
/// Icons are Lucide throughout, so the nav, the settings rail and the sidebar all
/// speak one visual language.
enum ShellSection {
  chat(
    LucideIcons.messageSquare,
    'Chat',
    thinIcon: LucideIcons.messageSquare300,
  ),
  scheduled(
    LucideIcons.calendarClock,
    'Scheduled',
    thinIcon: LucideIcons.calendarClock300,
  ),
  agents(LucideIcons.bot, 'Agents', thinIcon: LucideIcons.bot300),
  plugins(LucideIcons.puzzle, 'Plugins', thinIcon: LucideIcons.puzzle300),
  projects(
    LucideIcons.folderOpen,
    'Projects',
    thinIcon: LucideIcons.folderOpen300,
  ),
  messages(LucideIcons.send, 'Messages', thinIcon: LucideIcons.send300),
  grids(LucideIcons.zap, 'Grids', thinIcon: LucideIcons.zap300, devOnly: true),
  engines(LucideIcons.server, 'This computer', thinIcon: LucideIcons.server300),
  guide(
    LucideIcons.circleHelp,
    'How to use',
    thinIcon: LucideIcons.circleHelp300,
  ),
  // The sun — the Light choice's own glyph, so the row and the control it opens
  // agree. (A half-filled circle is the usual "theme" mark, but Lucide's reads
  // as a contrast/accessibility toggle at nav size.)
  appearance(LucideIcons.sun, 'Appearance', thinIcon: LucideIcons.sun300),
  debug(
    LucideIcons.terminal,
    'Debug',
    thinIcon: LucideIcons.terminal300,
    devOnly: true,
  );

  const ShellSection(
    this.icon,
    this.label, {
    required this.thinIcon,
    this.devOnly = false,
  });

  final IconData icon;
  final String label;

  /// The "300"-weight glyph, for the sidebar rail — a slightly different line
  /// weight than the default used elsewhere, tuned for the rail's rows.
  final IconData thinIcon;

  /// Internal tooling — shown only in developer builds. Raw grid management and
  /// the CLI log aren't for end users, so these are hidden from shipped release
  /// builds. See [isVisibleForBuild] and [AppEnvironment.isDeveloperMode].
  final bool devOnly;

  /// True for the screens Settings owns — they're drawn full-screen with the
  /// settings nav beside them, not inside the app shell.
  bool get isSettings => kSettingsSections.contains(this);

  /// Whether this section is offered in the current build: always in a developer
  /// build, and only when it isn't [devOnly] in a shipped release. Both the
  /// settings nav and the command palette gate on this.
  bool get isVisibleForBuild => !devOnly || AppEnvironment.isDeveloperMode;
}

/// What the sidebar's nav lists, in order.
///
/// Chat isn't among them (you get there by starting a chat or opening one), and
/// neither is Projects — your projects *are* the rail below, each holding its
/// chats; this section is the screen that manages them, opened from that header.
const kSidebarSections = [
  ShellSection.scheduled,
  ShellSection.plugins,
  ShellSection.agents,
];

/// What Settings lists, in order — the screens you set up once.
///
/// This computer leads, then Messages and the guide, then Appearance. Grids and
/// Debug are developer-only ([ShellSection.devOnly]) and hidden from shipped
/// builds, so an end user's list simply ends at Appearance.
///
/// Appearance sits below Grids but above Debug. That only shows up in a
/// developer build — where Grids is real work and Appearance is a preference, so
/// the preference gives way — and it costs an end user nothing, since both of the
/// rows around it are invisible to them either way.
const kSettingsSections = [
  ShellSection.engines,
  ShellSection.messages,
  ShellSection.guide,
  ShellSection.grids,
  ShellSection.appearance,
  ShellSection.debug,
];

/// Where Settings opens when the user asked for Settings rather than for one
/// screen inside it (the account menu, ⌘K) — the first screen every build shows.
/// This computer, not Grids: Grids is developer-only now, so it can't be the
/// landing screen an end user would get.
const kDefaultSettingsSection = ShellSection.engines;

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
