/// The app once it is connected: four places, and the bar that switches them.
///
/// Its own [Scaffold] rather than a body handed to [LinkScreen]'s, because the
/// bar along the bottom, the title above it and the "New" button in the corner
/// all belong to whichever tab is open — a frame owned upstairs would have to
/// be told about every one of them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chats.dart';
import '../logic/phone_link_controller.dart';
import 'chat_list_screen.dart';
import 'grid_app_bar.dart';
import 'grids_tab.dart';
import 'home_footer.dart';
import 'new_project_sheet.dart';
import 'parts.dart';
import 'projects_tab.dart';
import 'settings_tab.dart';

/// The connected app.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell(this.link, {super.key});

  /// What the computer told us, and what it is signed in to.
  final PhoneLinkConnected link;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  HomeTab _tab = HomeTab.chats;

  /// Re-asks the computer everything the open tab shows.
  ///
  /// The chats and projects are their own providers rather than part of the
  /// link's state, so refreshing the link alone would leave the list on screen
  /// exactly as stale as it was — the one thing a refresh button must not do.
  /// Invalidating is what re-asks them; it happens here rather than in the
  /// controller because those providers read *it*, and a controller reaching
  /// back into them would be a cycle.
  void _refresh() {
    ref.read(phoneLinkProvider.notifier).refresh();
    ref.invalidate(chatListProvider);
    ref.invalidate(projectsProvider);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      appBar: GridAppBar(
        title: _tab.label,
        actions: [
          GridBarButton(
            tooltip: 'Refresh',
            icon: Icons.refresh_rounded,
            onPressed: _refresh,
          ),
        ],
      ),
      // Stacked rather than rebuilt, so each tab keeps where it was scrolled to
      // and a half-read conversation isn't thrown away by a tap on the bar.
      //
      // Built from the enum rather than written out in order: the stack picks a
      // child by index, so a list that got out of step with [HomeTab] would put
      // the wrong screen under the right label, and nothing would flag it.
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tab.index,
          children: [for (final tab in HomeTab.values) _body(tab)],
        ),
      ),
      floatingActionButton: _action(),
      bottomNavigationBar: HomeFooter(
        current: _tab,
        onPick: (tab) => setState(() => _tab = tab),
      ),
    );
  }

  Widget _body(HomeTab tab) => switch (tab) {
    HomeTab.chats => const ChatListBody(),
    HomeTab.projects => const ProjectsTab(),
    HomeTab.grids => GridsTab(widget.link.grids),
    HomeTab.settings => SettingsTab(widget.link),
  };

  /// The one thing you can start from the tab you are on, or nothing — the
  /// grids and the paired computer are read here; both are changed at the
  /// computer.
  Widget? _action() => switch (_tab) {
    HomeTab.chats => const NewChatButton(),
    HomeTab.projects => GridFab(
      tooltip: 'New project',
      onPressed: () => showNewProjectSheet(context),
    ),
    HomeTab.grids || HomeTab.settings => null,
  };
}
