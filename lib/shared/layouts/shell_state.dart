import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_environment.dart';

/// The two halves of the app, chosen at the top of the sidebar.
///
/// They are separate on purpose rather than one more row in the nav: the words
/// mean different things on each side. A *project* in [home] is a folder on
/// this computer the assistant may read; a *project* in [code] is a repository
/// the grid hosts, with members and a trunk. A *task* in [home] is something
/// the assistant does on a timer; a *task* in [code] is one agent run on
/// somebody else's machine. Putting both in one rail would force one of each
/// pair to be renamed into something nobody says out loud.
enum ShellMode {
  /// Chatting, and everything that shapes how the assistant answers.
  home(LucideIcons.house300, 'Home'),

  /// Handing coding work to the grid: shared repositories, and the agent runs
  /// against them.
  ///
  /// Developer-only for now: the half is built, but the relay in production
  /// serves no projects plane, so a shipped build would offer a whole side of
  /// the app whose every screen answers "nothing here" — and the switch above
  /// it would be the first thing a new user clicked.
  code(LucideIcons.codeXml300, 'Code', devOnly: true);

  const ShellMode(this.icon, this.label, {this.devOnly = false});

  /// The switch's glyph and word. Carried here rather than typed into the
  /// segmented control, so a half that is hidden takes its label with it — the
  /// same reason [ShellSection] carries its own.
  final IconData icon;
  final String label;

  /// Internal half — offered only in developer builds, like
  /// [ShellSection.devOnly].
  final bool devOnly;

  /// Whether this half is offered in the current build.
  bool get isVisibleForBuild => !devOnly || AppEnvironment.isDeveloperMode;
}

/// The halves this build offers, in order — what the switch draws, and the only
/// modes [ShellModeNotifier.select] accepts.
List<ShellMode> get visibleShellModes => [
  for (final mode in ShellMode.values)
    if (mode.isVisibleForBuild) mode,
];

/// Which half is open. Session state — the app opens on [ShellMode.home], which
/// is what it is for.
final shellModeProvider = NotifierProvider<ShellModeNotifier, ShellMode>(
  ShellModeNotifier.new,
);

class ShellModeNotifier extends Notifier<ShellMode> {
  @override
  ShellMode build() => ShellMode.home;

  /// Open [mode], unless this build doesn't offer it.
  ///
  /// The guard rather than trusting the switch to be the only way in: the switch
  /// is hidden in a release build, so anything that ever reaches here with a
  /// dev-only half would strand the user in a side of the app with no control to
  /// leave it by.
  void select(ShellMode mode) {
    if (!mode.isVisibleForBuild) return;
    state = mode;
  }
}

/// Whether the left rail is folded down to its glyphs to give the pane more of
/// the window.
///
/// Folded, **not gone**: `AppSidebarMini` takes the wide rail's place, so the
/// app keeps its navigation at every width and the fold costs only what needs
/// words (the chat list, the project tree). A rail that vanished left the whole
/// nav behind one borrowed button in the top bar.
///
/// Session state, like [shellModeProvider]: a rail you collapsed to read a wide
/// diff should come back on the next launch, which is what the app is *for*.
/// The toggle lives on the rail's own head in both states — the same [toggle].
final sidebarCollapsedProvider =
    NotifierProvider<SidebarCollapsedNotifier, bool>(
      SidebarCollapsedNotifier.new,
    );

class SidebarCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

/// Whether the chat screen is the one actually on screen.
///
/// The section alone stopped being the answer the moment [ShellMode.code]
/// existed: Code replaces the pane wholesale, so `section == chat` can be true
/// while the user is looking at a task. Everything that decorates chat — the
/// top bar's header, its panel toggles — asks this instead, in one place, so
/// they cannot drift apart.
final chatIsOpenProvider = Provider<bool>(
  (ref) =>
      ref.watch(shellModeProvider) == ShellMode.home &&
      ref.watch(shellSectionProvider) == ShellSection.chat,
);

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
  skills(LucideIcons.sparkles, 'Skills', thinIcon: LucideIcons.sparkles300),
  connectors(LucideIcons.cable, 'Connectors', thinIcon: LucideIcons.cable300),
  // Still dev-only while Skills and Connectors have shipped. The three used to
  // be gated together — "ready to ship at once" — and this is that plan being
  // decided rather than abandoned: Plugins is the one whose backend is not
  // there for every agent (Codex has no plugin manager at all, so its plane is
  // permanently null), which would leave an end user on a screen that tells
  // them their agent can't do this.
  plugins(
    LucideIcons.puzzle,
    'Plugins',
    thinIcon: LucideIcons.puzzle300,
    devOnly: true,
  ),
  projects(
    LucideIcons.folderOpen,
    'Projects',
    thinIcon: LucideIcons.folderOpen300,
  ),
  git(LucideIcons.gitBranch, 'Git', thinIcon: LucideIcons.gitBranch300),
  messages(
    LucideIcons.send,
    'Messages',
    thinIcon: LucideIcons.send300,
    devOnly: true,
  ),
  grids(LucideIcons.zap, 'Grids', thinIcon: LucideIcons.zap300, devOnly: true),
  // "Model engines", not "This computer": the rail names what a row *is*, and
  // a row called after a place tells a first-time user nothing about the thing
  // this app exists to do. The screen's own title says the same words — it was
  // "Model Engines" there and "This computer" in the nav, which is one concept
  // wearing two names (§5).
  engines(LucideIcons.server, 'Model engines', thinIcon: LucideIcons.server300),
  guide(
    LucideIcons.circleHelp,
    'How to use',
    thinIcon: LucideIcons.circleHelp300,
  ),
  // The sun — the Light choice's own glyph, so the row and the control it opens
  // agree. (A half-filled circle is the usual "theme" mark, but Lucide's reads
  // as a contrast/accessibility toggle at nav size.)
  appearance(LucideIcons.sun, 'Appearance', thinIcon: LucideIcons.sun300),
  dataSync(LucideIcons.cloud, 'Sync & Backup', thinIcon: LucideIcons.cloud300),
  archived(
    LucideIcons.archive,
    'Archived chats',
    thinIcon: LucideIcons.archive300,
  ),
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
/// Agents isn't either: picking which assistant answers is setup you do once,
/// and the composer already switches it per chat — so it sits in Settings with
/// the rest of what shapes the answer.
///
/// [ShellSection.engines] leads, and it is the one row here that isn't a
/// convenience: running a model is what the product *is*, and it used to be
/// three clicks deep behind the account menu ▸ Settings, on a screen that took
/// the whole window. Every other way in was a dead end reacting to a failure —
/// "Start an engine" on an empty chat, the failed-download pill — so a user who
/// simply wanted to host had nowhere to click.
const kSidebarSections = [ShellSection.engines, ShellSection.scheduled];

/// One labelled run of rows in the settings nav.
///
/// The list was a flat eight rows, which reads as a pile once the developer
/// build unhides the last four: nothing tells you that Plugins and Messages are
/// the same kind of thing and Appearance isn't. Grouping is presentation only —
/// [kSettingsSections] still flattens to the same set, so [ShellSection.isSettings]
/// and the ⌘K palette are untouched.
class SettingsGroup {
  const SettingsGroup(this.title, this.sections);

  /// The heading above the run. Kept short — it's a caption, not a sentence.
  final String title;

  /// The rows under it, in order. May be entirely [ShellSection.devOnly], in
  /// which case the whole group — heading included — disappears from a shipped
  /// build; see [visibleSettingsGroups].
  final List<ShellSection> sections;
}

/// What Settings lists, in order — the screens you set up once, in labelled runs.
///
/// Personal is what an end user actually touches; Integrations is what the app
/// talks to on their behalf; Developer is the [ShellSection.devOnly] tooling,
/// which vanishes wholesale in a shipped build; Archived trails everything as
/// storage rather than setup.
///
/// Messages and Plugins sit together because they are the same shape — both
/// point the assistant at something outside the app (a Telegram gateway, the
/// skills/MCP it may call) — even though both are developer-gated today.
const kSettingsGroups = [
  // No "This computer" row: [ShellSection.engines] moved out to the sidebar (see
  // [kSidebarSections]). It was never plumbing you set up once — it is the
  // screen a host comes back to every time they add a model or stop an engine,
  // and Settings takes the whole window, so arriving there dropped the grid and
  // the chat behind it.
  SettingsGroup('Personal', [
    ShellSection.appearance,
    // Between Appearance and the guide: it is about this user's own data on
    // this computer, which is what the rest of this group is about. It is not
    // a Grid you talk to (Developer) nor something that shapes an answer
    // (Customize).
    ShellSection.dataSync,
    ShellSection.guide,
  ]),
  // What the assistant is and what it can do — mirrors the mental model of
  // other agent apps' settings. Agents leads: which assistant runs is the
  // choice the rows under it modify. Agents, Skills and Connectors ship to
  // everyone; Plugins stays dev-only, so a release build draws this group with
  // three rows rather than four. The heading survives because the group still
  // has rows — see [visibleSettingsGroups], which is also what would drop it
  // silently if the last public row were ever gated again.
  SettingsGroup('Customize', [
    ShellSection.agents,
    ShellSection.skills,
    ShellSection.connectors,
    ShellSection.plugins,
  ]),
  // The toolchain the assistant writes code with, as opposed to what it may
  // call (Customize, above). One row today; it is its own group because Git is
  // the first of a set that belongs together — branch switching, a worktree per
  // parallel agent, reviewing a project's diff — and filing the first one under
  // "Personal" would mean moving it the moment the second arrives.
  SettingsGroup('Coding', [ShellSection.git]),
  SettingsGroup('Integrations', [
    // dev only for now, so this whole group is invisible in a shipped build.
    ShellSection.messages,
  ]),
  SettingsGroup('Developer', [ShellSection.grids, ShellSection.debug]),
  // Where a chat goes when it leaves the sidebar. Its own run at the bottom:
  // it's the one row here that manages content rather than configuration.
  SettingsGroup('Archived', [ShellSection.archived]),
];

/// Every settings screen, flat — the membership test behind
/// [ShellSection.isSettings]. Derived from [kSettingsGroups] so a row can never
/// be in the nav without counting as a settings screen, or the reverse.
final kSettingsSections = [
  for (final group in kSettingsGroups) ...group.sections,
];

/// [kSettingsGroups] narrowed to this build: rows that fail
/// [ShellSection.isVisibleForBuild] drop out, and a group left with no rows drops
/// out with them — so a shipped build never draws a heading over nothing.
List<SettingsGroup> visibleSettingsGroups({
  bool Function(ShellSection)? where,
}) {
  final groups = <SettingsGroup>[];
  for (final group in kSettingsGroups) {
    final rows = [
      for (final target in group.sections)
        if (target.isVisibleForBuild && (where?.call(target) ?? true)) target,
    ];
    if (rows.isNotEmpty) groups.add(SettingsGroup(group.title, rows));
  }
  return groups;
}

/// Where Settings opens when the user asked for Settings rather than for one
/// screen inside it (the account menu, ⌘K) — the first screen every build shows.
/// Appearance, not Grids: Grids is developer-only now, so it can't be the
/// landing screen an end user would get. It was Model engines until that screen
/// left Settings for the sidebar.
const kDefaultSettingsSection = ShellSection.appearance;

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
  ///
  /// A **work** section also brings the user back to [ShellMode.home], because
  /// that is the half of the app those sections live in. Without it, everything
  /// that says "go to Chat" from outside the rail — a tray notification, a
  /// clicked desktop alert, ⌘K, a scheduled task's result — would select the
  /// chat *behind* a Code pane the user is still looking at, and appear to have
  /// done nothing.
  ///
  /// A **settings** section deliberately does not: Settings takes the whole
  /// window from either half, and "Back to app" has to return to the one the
  /// user left.
  void select(ShellSection section) {
    if (section.isSettings) {
      if (!state.isSettings) previous = state;
      state = section;
      return;
    }
    ref.read(shellModeProvider.notifier).select(ShellMode.home);
    state = section;
  }

  /// The work section the user was on before opening Settings — Chat by
  /// default, or whichever of Grids/Activity/etc. they were looking at.
  ShellSection previous = ShellSection.chat;
}
