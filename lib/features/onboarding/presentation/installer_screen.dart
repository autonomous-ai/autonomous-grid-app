import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/onboarding_page.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/log_view.dart';
import '../logic/installer_controller.dart';
import '../logic/installer_copy.dart';
import '../logic/installer_rows.dart';
import '../logic/installer_stage.dart';
import 'widgets/installer_step_row.dart';

/// First-run setup, as a screen the user watches rather than a chore hidden in
/// a banner: make sure they have a grid, install the engine, and install the
/// assistant — enough to start chatting. The model (several GB) is not here; it
/// downloads in the background afterwards, with its progress in the top bar.
///
/// It starts on its own — a new user has nothing to decide — and says at every
/// moment which step is running, what's left, and what went wrong.
class InstallerScreen extends ConsumerStatefulWidget {
  const InstallerScreen({super.key});

  @override
  ConsumerState<InstallerScreen> createState() => _InstallerScreenState();
}

class _InstallerScreenState extends ConsumerState<InstallerScreen> {
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    // Post-frame: never mutate state during the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(installerControllerProvider) is InstallerIdle) {
        ref.read(installerControllerProvider.notifier).run();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(installerRowsProvider);
    final state = ref.watch(installerControllerProvider);
    final done = rows.where((r) => r.status == InstallStatus.done).length;

    return OnboardingPage(
      title: installerHeadline(state),
      subtitle: installerSubtitle(state),
      meta: '$done of ${rows.length} steps',
      children: [
        AppProgressBar(value: rows.isEmpty ? 0 : done / rows.length),
        const SizedBox(height: 20),
        for (final row in rows) InstallerStepRow(row: row),
        const SizedBox(height: 8),
        _Details(
          expanded: _showDetails,
          onToggle: () => setState(() => _showDetails = !_showDetails),
        ),
        const SizedBox(height: 20),
        _Actions(state: state),
      ],
    );
  }
}

/// The collapsible log — hidden by default, because a first-time user shouldn't
/// have to read CLI output, and available for when something goes wrong.
class _Details extends ConsumerWidget {
  const _Details({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(installerLogProvider);
    if (log.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onToggle,
            // Quiet, not accent: the CLI log is the last thing on this screen
            // that should pull a first-time user's eye.
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.textSecondary,
            ),
            icon: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 18,
            ),
            label: Text(expanded ? 'Hide details' : 'Show details'),
          ),
        ),
        if (expanded) SizedBox(height: 160, child: LogView(lines: log)),
      ],
    );
  }
}

/// What the user can do, which depends entirely on where the install is: wait
/// (with a way out), retry, or go in.
class _Actions extends ConsumerWidget {
  const _Actions({required this.state});

  final InstallerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(installerControllerProvider.notifier);
    // Every way *out* of this screen is quiet; only the way forward is a button.
    final quiet = TextButton.styleFrom(
      foregroundColor: AppPalette.textSecondary,
    );

    return switch (state) {
      InstallerRunning() => Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: controller.cancel,
          style: quiet,
          child: const Text('Cancel'),
        ),
      ),
      // Wrap, not Row: the window can be narrow, and these labels are long — a
      // Row overflows instead of folding.
      InstallerFailed() => Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton(
            onPressed: controller.skip,
            style: quiet,
            child: const Text('Continue without this computer'),
          ),
          FilledButton(
            onPressed: controller.run,
            child: const Text('Try again'),
          ),
        ],
      ),
      InstallerIdle() => Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton(
            onPressed: controller.skip,
            style: quiet,
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: controller.run,
            child: const Text('Set up this computer'),
          ),
        ],
      ),
      // Both leave the installer, so the screen is already on its way out.
      InstallerDone() || InstallerSkipped() => const SizedBox.shrink(),
    };
  }
}
