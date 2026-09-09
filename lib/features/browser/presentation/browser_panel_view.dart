import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/external_launch.dart';
import '../../../shared/panels/panel_tabs.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/panel_body.dart';
import '../logic/browser_page.dart';
import '../logic/browser_tab_controller.dart';
import '../logic/browser_url.dart';
import 'widgets/browser_page_view.dart';
import 'widgets/browser_toolbar.dart';

/// A web page in a panel tab: the toolbar, the loading line, and the page.
///
/// Mounted by the panel's mapping table the same way Review, Terminal and Files
/// are — and unlike them it is rooted at nothing on this computer, so it takes
/// only the tab it belongs to. Both panels use this widget rather than a copy
/// each, which is what keeps the tab beside a chat and the tab beside a project
/// from drifting into two browsers with different habits.
class BrowserPanelView extends ConsumerWidget {
  const BrowserPanelView({super.key, required this.host, required this.tabId});

  /// Which panel this tab is in — only so the page's name can be put on the
  /// tab; see [PanelTabs.rename].
  final PanelHost host;

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = browserTabProvider(tabId);
    final name = ref.watch(
      tab.select(
        (s) => browserTabTitle(title: s.title, url: s.url, fallback: ''),
      ),
    );

    // The page's own name goes on the tab, so a row of them can be told apart.
    // Empty while the tab has been opened and not yet pointed anywhere, and
    // that is deliberately left alone: the tab keeps the "Browser 2" it was
    // opened under rather than becoming a second tab called "Browser".
    //
    // After the frame, never during it: writing a provider while another is
    // building is what Riverpod forbids outright.
    if (name.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(panelTabsProvider(host).notifier).rename(tabId, name);
        }
      });
    }

    return PanelBody(
      toolbar: BrowserToolbar(tabId: tabId),
      main: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrowserLoadingLine(tabId: tabId),
          Expanded(child: _Page(tabId: tabId)),
        ],
      ),
    );
  }
}

/// The page, and whatever has to be said instead of it.
///
/// The engine stays mounted under every overlay: it is what holds the history,
/// and a tab that threw its engine away to show an error message would come
/// back with no Back button.
class _Page extends ConsumerWidget {
  const _Page({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(browserTabProvider(tabId).select((s) => s.load));
    return Stack(
      fit: StackFit.expand,
      children: [
        BrowserPageView(tabId: tabId),
        switch (load) {
          BrowserIdle() => const _StartOverlay(),
          BrowserFailed(:final message, :final url) => _FailureOverlay(
            tabId: tabId,
            message: message,
            url: url,
          ),
          // Nothing over a page that is arriving or has arrived — the loading
          // line above says the rest.
          BrowserLoading() || BrowserReady() => const SizedBox.shrink(),
        },
      ],
    );
  }
}

/// A tab that has been opened and not yet pointed anywhere.
///
/// Opaque, because the engine behind it is a blank white page in a window that
/// may well be dark.
class _StartOverlay extends StatelessWidget {
  const _StartOverlay();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ColoredBox(
      color: AppPalette.panelBg,
      child: const EmptyState(
        icon: LucideIcons.globe,
        title: 'Nothing open yet',
        message: 'Type an address in the bar above, or search from it.',
      ),
    );
  }
}

/// The page didn't arrive.
///
/// Both ways forward are offered, because either can be the right one: the
/// address may be fine and the connection not, or the page may be one this tab
/// can't show and the user's own browser can.
class _FailureOverlay extends ConsumerWidget {
  const _FailureOverlay({
    required this.tabId,
    required this.message,
    required this.url,
  });

  final String tabId;
  final String message;
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ColoredBox(
      color: AppPalette.panelBg,
      child: EmptyState(
        icon: LucideIcons.triangleAlert,
        title: "Couldn't open ${hostLabel(url)}",
        // The engine's own sentence, which is usually the useful one — "The
        // Internet connection appears to be offline", "A server with the
        // specified hostname could not be found".
        message: message,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: ref
                  .read(browserTabProvider(tabId).notifier)
                  .reloadOrStop,
              child: const Text('Try again'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => openExternalUrl(url),
              child: const Text('Open in your browser'),
            ),
          ],
        ),
      ),
    );
  }
}
