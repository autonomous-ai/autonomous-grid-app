import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/browser/logic/browser_tab_controller.dart';
import '../features/code/logic/code_projects_controller.dart';
import '../infrastructure/state/chat_prefs_store.dart';
import 'external_launch.dart';
import 'layouts/shell_state.dart';
import 'panels/panel_tabs.dart';

/// The panel that sits beside whichever conversation the user is looking at, or
/// null when there is none.
///
/// Home's is the preview panel beside the chat. Code's is the panel beside a
/// project — and only while a project is open, since Code with none is a list,
/// and a tab opened onto that is a tab waiting behind a screen the user cannot
/// see it from.
///
/// Naming a feature's provider from `shared/` is the exemption `panel_tabs.dart`
/// and the panel mapping tables already take: a table that maps panels onto the
/// screens holding them has to name both sides.
PanelHost? conversationPanelHost(WidgetRef ref) {
  if (ref.read(shellModeProvider) != ShellMode.code) return PanelHost.preview;
  return ref.read(codeProjectIsOpenProvider) ? PanelHost.code : null;
}

/// Open a link the user clicked in something the app is *showing* them — a
/// message, a rendered Markdown file.
///
/// Where it opens is theirs to decide (Settings ▸ Browser): the browser they
/// already have, which is the default and where their logins live, or a Browser
/// tab beside what they were reading.
///
/// Deliberately not the door the app's own errands use. A sign-in, a "show this
/// in Finder", the Browser tab's own "Open in your browser" all call
/// [openExternalUrl] directly, because those either need the user's real
/// browser or are already an explicit request to leave.
void openContentLink(WidgetRef ref, String href) {
  final host = ref.read(chatPrefsProvider).browserOpensLinks
      ? conversationPanelHost(ref)
      : null;
  // Nothing to open it beside — or this computer has no engine to draw it with
  // (see [availablePanelFeatures]). Either way the honest answer is the browser
  // that does, not a click that does nothing.
  if (host == null || !availablePanelFeatures.contains(PanelFeature.browser)) {
    openExternalUrl(href);
    return;
  }

  // Back to the chat first when that is where the panel lives: firing this from
  // a settings screen would otherwise open a tab the user can't see.
  if (host == PanelHost.preview) {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  // A new tab every time, never a jump into the one already open: a link is a
  // place you are going *as well as* what you were reading, and reusing the tab
  // would throw away the page it was on.
  final id = ref
      .read(panelTabsProvider(host).notifier)
      .open(PanelFeature.browser);
  ref.read(browserTabProvider(id).notifier).submit(href);
}
