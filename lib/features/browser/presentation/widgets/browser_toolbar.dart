import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/external_launch.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/browser_page.dart';
import '../../logic/browser_tab_controller.dart';
import 'browser_address_bar.dart';

/// Region 2 of a Browser tab: back, forward, reload, the address, and the way
/// out to the user's own browser.
///
/// The same shape every browser has had for twenty years, in the panel's own
/// 36px row — the point of a familiar toolbar is that nobody has to be told
/// what it does.
class BrowserToolbar extends ConsumerWidget {
  const BrowserToolbar({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = browserTabProvider(tabId);
    final canGoBack = ref.watch(tab.select((s) => s.canGoBack));
    final canGoForward = ref.watch(tab.select((s) => s.canGoForward));
    final busy = ref.watch(tab.select((s) => s.isBusy));
    final url = ref.watch(tab.select((s) => s.url));
    final controller = ref.read(tab.notifier);

    return Padding(
      // The inset Review and Files both take, so the row under the tabs starts
      // in the same place whichever tab you switch to.
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          AppIconButton(
            icon: LucideIcons.arrowLeft300,
            size: 15,
            tooltip: 'Back',
            // Null disables rather than hides: a toolbar whose buttons come and
            // go as you browse moves the address bar under the pointer.
            onPressed: canGoBack ? controller.back : null,
          ),
          const SizedBox(width: 2),
          AppIconButton(
            icon: LucideIcons.arrowRight300,
            size: 15,
            tooltip: 'Forward',
            onPressed: canGoForward ? controller.forward : null,
          ),
          const SizedBox(width: 2),
          AppIconButton(
            icon: busy ? LucideIcons.x300 : LucideIcons.refreshCw300,
            size: 14,
            tooltip: busy ? 'Stop loading' : 'Reload this page',
            onPressed: controller.reloadOrStop,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              // Shorter than the 36px row it sits in, so the field reads as
              // something *in* the toolbar rather than as the toolbar itself.
              height: 26,
              child: BrowserAddressBar(url: url, onSubmit: controller.submit),
            ),
          ),
          const SizedBox(width: 8),
          AppIconButton(
            icon: LucideIcons.squareArrowOutUpRight300,
            size: 15,
            tooltip: url.isEmpty
                ? 'Open a page to send it to your browser'
                : 'Open in your browser',
            // The way out for everything this tab is not: an extension, a saved
            // password, a download. It is a panel beside a conversation, not a
            // replacement for the browser the user already has.
            onPressed: url.isEmpty ? null : () => openExternalUrl(url),
          ),
        ],
      ),
    );
  }
}

/// The hairline that fills as a page arrives.
///
/// Under the toolbar rather than across the page: a bar drawn over the content
/// covers the top of the page it is describing, and this one has to sit on a
/// seam that is already there.
class BrowserLoadingLine extends ConsumerWidget {
  const BrowserLoadingLine({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(browserTabProvider(tabId).select((s) => s.load));
    if (load is! BrowserLoading) return const SizedBox(height: 2);
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        minHeight: 2,
        // The engine's number, not an animation of our own: a bar that moves on
        // its own timing tells the user the page is coming when it may not be.
        value: load.progress,
      ),
    );
  }
}
