/// The strip across the top of every screen while the link is coming back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';

/// Puts [LinkBanner] above whatever [child] is — the whole navigator.
///
/// Above the navigator rather than inside one screen, because a drop happens
/// wherever somebody is: in a chat three screens deep, the home shell's own
/// banner would be under two routes and say nothing. The child loses its top
/// safe-area inset while the strip shows, since the strip is what now sits
/// under the status bar.
class LinkBannerFrame extends ConsumerWidget {
  const LinkBannerFrame({required this.child, super.key});

  /// The app underneath.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(phoneLinkProvider);
    final dropped = state is PhoneLinkInterrupted;
    // The same two children whether or not the strip shows. Returning [child]
    // bare when the link is fine would move the navigator to another place in
    // the tree on every drop — and a navigator that moves is rebuilt, which
    // throws away every screen somebody had open.
    return Column(
      children: [
        if (state is PhoneLinkInterrupted)
          LinkBanner(state)
        else
          const SizedBox.shrink(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: dropped,
            child: child,
          ),
        ),
      ],
    );
  }
}

/// "Reconnecting…", or why it could not, with the way to try again.
class LinkBanner extends ConsumerWidget {
  const LinkBanner(this.state, {super.key});

  /// The dropped link being put back.
  final PhoneLinkInterrupted state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final host = state.last.hostName.isEmpty
        ? 'your computer'
        : state.last.hostName;
    final problem = state.problem;
    return Material(
      color: AppPalette.cardBg,
      child: SafeArea(
        bottom: false,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppPalette.divider)),
          ),
          child: Row(
            children: [
              if (problem == null) const _Spinner() else const _Warning(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  problem == null
                      ? 'Reconnecting to $host…'
                      : "Can't reach $host. $problem",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ),
              if (problem != null)
                TextButton(
                  onPressed: () =>
                      ref.read(phoneLinkProvider.notifier).reconnect(),
                  child: const Text('Try again'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox.square(
      dimension: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: AppPalette.textFaint,
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Icon(
      Icons.cloud_off_rounded,
      size: 16,
      color: AppPalette.textSecondary,
    );
  }
}
