import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../shared/external_launch.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../logic/adapters/claude_browser.dart';
import '../logic/adapters/claude_browser_access.dart';
import '../logic/agent_browser_controller.dart';
import '../logic/chrome_setup_controller.dart';

/// Which browser the chat on screen would reach on its next turn, and the one
/// step that widens it.
///
/// The app decided this per turn all along and told only `~/.grid/logs`, so an
/// agent that quietly never opened a browser looked like an agent that wouldn't
/// — the four things that shut the lane are all fixable, and none of them was
/// visible from inside the app.
class BrowserAccessBlock extends ConsumerWidget {
  const BrowserAccessBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final access = ref.watch(browserAccessProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppGlass.hair),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_laneIcon(access.lane), size: 15, color: _laneInk(access.lane)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  access.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textPrimary,
                    fontWeight: AppFont.medium,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  access.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
                if (access.step case final step?) ...[
                  const SizedBox(height: 9),
                  _StepActions(step: step),
                ],
                const _SetupOutcome(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The lane's mark: the browser the user already has, a window of the app's own,
/// or nothing.
IconData _laneIcon(ClaudeBrowserLane lane) => switch (lane) {
  ClaudeBrowserLane.extension => LucideIcons.globe300,
  ClaudeBrowserLane.cdp => LucideIcons.appWindow300,
  ClaudeBrowserLane.none => LucideIcons.globeLock300,
};

/// Green only for the lane that reaches the user's own logins — the one people
/// mean when they ask for browser access. The fallback works, but it is signed
/// in to nothing, so it doesn't get to wear a success colour.
Color _laneInk(ClaudeBrowserLane lane) => switch (lane) {
  ClaudeBrowserLane.extension => AppPalette.online,
  ClaudeBrowserLane.cdp => AppPalette.textSecondary,
  ClaudeBrowserLane.none => AppPalette.offline,
};

/// What to press: the step itself, plus a way to re-read a computer the user
/// just changed outside the app.
class _StepActions extends ConsumerWidget {
  const _StepActions({required this.step});

  final BrowserSetupStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    if (ref.watch(chromeSetupProvider) is ChromeSetupRunning) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 9),
          Text(
            'Connecting Chrome…',
            style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        switch (step) {
          BrowserSetupStep.installExtension => OutlinedButton(
            onPressed: () => openExternalUrl(kClaudeInChromeStoreUrl),
            child: const Text('Get the extension'),
          ),
          BrowserSetupStep.connectChrome => FilledButton(
            onPressed: ref.read(chromeSetupProvider.notifier).connect,
            child: const Text('Connect my Chrome'),
          ),
        },
        TextButton(
          onPressed: ref.read(agentBrowserProvider).recheck,
          child: const Text('Check again'),
        ),
      ],
    );
  }
}

/// How the connect step ended — the restart it now needs, or why it didn't take.
///
/// Success is not silent here: the file lands on disk, the card flips to "works
/// in your Chrome", and the browser still won't answer until Chrome is restarted
/// (it reads this at startup). A card that only flipped would be lying by
/// omission for one restart.
class _SetupOutcome extends ConsumerWidget {
  const _SetupOutcome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final setup = ref.watch(chromeSetupProvider);
    return switch (setup) {
      ChromeSetupIdle() || ChromeSetupRunning() => const SizedBox.shrink(),
      ChromeSetupDone() => _Note(
        text:
            'Connected. Quit Chrome and open it again — that is when it picks '
            'this up.',
        color: AppPalette.online,
      ),
      ChromeSetupFailed(:final message) => _Note(
        text: message,
        color: AppPalette.warn,
      ),
    };
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: TextStyle(fontSize: 12, color: color)),
  );
}
