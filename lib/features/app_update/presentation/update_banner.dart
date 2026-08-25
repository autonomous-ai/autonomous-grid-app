import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/app_updater_service.dart';
import '../logic/appcast_feed.dart';
import '../logic/update_watcher.dart';

/// The card at the foot of the sidebar that says a new version is out.
///
/// It sits above the account row because that is the rail's quiet end — the
/// part of the window nothing else competes for — and because an update is news
/// about the app itself, which is what that corner already holds.
///
/// Draws nothing at all until there is a release to name, so every caller can
/// place it unconditionally.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({this.compact = false, super.key});

  /// Folded rail: one round button instead of a card. 284px of sidebar has room
  /// for a sentence; 56 has room for an icon, and a badge nobody can act on is
  /// worse than the button that installs the thing.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(updateWatcherProvider);
    if (release == null) return const SizedBox.shrink();
    return compact ? _CompactButton(release: release) : _Card(release: release);
  }
}

/// Hand the release over to Sparkle to fetch, verify and install.
///
/// The app found the update but does not install it: Sparkle checks the EdDSA
/// signature against `SUPublicEDKey`, swaps the bundle in one move, and
/// relaunches. Re-implementing that is how an updater bricks the app it is
/// updating, and a broken app cannot be fixed from here.
///
/// TODO(BE): the two lanes keep separate memories and can contradict each other
/// out loud. If the user ever answered "Skip This Version" in Sparkle's own
/// dialog, that version is dead to Sparkle but still live to this banner — so
/// pressing Update here answers "You're up to date!" while the banner beside it
/// says the opposite. Sparkle's skip flag lives in its `UserDefaults` and there
/// is no plugin API to read or clear it; the fix is the forked user driver that
/// makes this banner the only dialog there is.
void _install(WidgetRef ref) =>
    ref.read(appUpdaterServiceProvider).checkForUpdates();

class _Card extends ConsumerWidget {
  const _Card({required this.release});

  final AppcastRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: BorderRadius.circular(AppControl.radius + 2),
          border: Border.all(color: AppPalette.divider),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Headline(release: release),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, AppControl.heightSmall),
                    padding: AppControl.paddingSmall,
                  ),
                  onPressed: () => _install(ref),
                  child: const Text('Update'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line that names the release, and the ✕ that closes it.
class _Headline extends ConsumerWidget {
  const _Headline({required this.release});

  final AppcastRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.system_update_alt_rounded,
            size: 15,
            color: AppPalette.accentOnSurface,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Grid ${release.shortVersion} is out',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                'Installs and restarts the app.',
                style: TextStyle(color: AppPalette.textFaint, fontSize: 11.5),
              ),
            ],
          ),
        ),
        IconButton(
          // Says what closing actually does. "Not now" would promise the banner
          // comes back for this same release, and it doesn't — only a later one
          // reopens it.
          tooltip: 'Hide until the next release',
          onPressed: () => ref.read(updateWatcherProvider.notifier).dismiss(),
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          color: AppPalette.textFaint,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

/// The folded rail's version: one button, no ✕.
///
/// Nothing to close here, on purpose — a folded rail has no room to explain what
/// closing would mean, and the button is small enough not to be in anyone's way.
class _CompactButton extends ConsumerWidget {
  const _CompactButton({required this.release});

  final AppcastRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: IconButton(
        tooltip: 'Grid ${release.shortVersion} is out — update',
        onPressed: () => _install(ref),
        iconSize: 17,
        color: AppPalette.accentOnSurface,
        icon: const Icon(Icons.system_update_alt_rounded),
      ),
    );
  }
}
