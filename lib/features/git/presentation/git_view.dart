import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/git_probe.dart';
import '../../../infrastructure/cli/git_providers.dart';
import '../../../infrastructure/cli/git_release_pins.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/git_missing_notice.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/git_install_controller.dart';

/// Whether this computer has a Git the assistant can run, and which one.
///
/// One card, because there is one question: an agent working in a project runs
/// `git` constantly, and when the answer is "there isn't one" every failure it
/// causes surfaces somewhere else — inside a plugin install, inside a terminal
/// step — wearing git's words rather than ours. This is the one place that says
/// it plainly, with the way out.
///
/// Nothing here is normally needed: Git arrives in the background at first
/// launch. What the screen is for is the machine where that didn't happen.
class GitView extends ConsumerWidget {
  const GitView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Git',
      subtitle:
          'Agents run Git while they work in your projects. Grid uses the one '
          'already on this computer, and only installs its own if there is '
          'none.',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // The width Agents and Plugins bound their rows to — a status line
          // that runs the full width of a large window puts its two ends too
          // far apart to read in one glance.
          constraints: const BoxConstraints(maxWidth: 940),
          child: ListView(
            children: const [_GitCard(), SizedBox(height: 10), _WhatItIsFor()],
          ),
        ),
      ),
    );
  }
}

/// Where Git stands on this computer, and what to do when that isn't enough.
class _GitCard extends ConsumerWidget {
  const _GitCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final status = ref.watch(gitStatusProvider);

    // Every finished check or install says what it found. Without this the
    // buttons read as dead controls: the probe answers in about ten
    // milliseconds, so on a computer whose Git hasn't changed, Check again
    // moves nothing on screen at all.
    //
    // Which is why the line is derived from the status rather than handed over
    // ready-made — a re-check that still finds no Git has finished, but saying
    // so in green would be a lie.
    ref.listen(gitInstallProvider, (_, next) {
      if (next is! GitInstallDone) return;
      final (message, severity) = switch (next.status) {
        GitReady(:final version, ours: true) => (
          'Using Git ${gitVersionLabel(version)}, the copy Grid installed.',
          ToastSeverity.success,
        ),
        GitReady(:final version) => (
          'Using Git ${gitVersionLabel(version)} from this computer.',
          ToastSeverity.success,
        ),
        GitTooOld(:final version) => (
          'Git ${gitVersionLabel(version)} is still too old for Grid.',
          ToastSeverity.warning,
        ),
        GitCannotCarryCredential(:final version) => (
          "Git ${gitVersionLabel(version)} still can't sign in to your grid.",
          ToastSeverity.warning,
        ),
        GitMissing() => (
          'Still no Git this computer can run.',
          ToastSeverity.warning,
        ),
      };
      ToastScope.show(context, ToastSpec(message: message, severity: severity));
    });

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 15, 14),
        child: switch (status) {
          // Still probing. A row that said "no Git" for the half-second the
          // process takes would send people off to install one they have.
          AsyncLoading() => const _Looking(),
          // The probe swallows its own failures and answers GitMissing, so the
          // error arm is unreachable in practice — worth the same body rather
          // than a claim that it can't happen.
          AsyncValue(:final value) => _Status(
            status: value ?? const GitMissing(),
          ),
        },
      ),
    );
  }
}

class _Looking extends StatelessWidget {
  const _Looking();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return Row(
      children: [
        const AppSpinner(),
        const SizedBox(width: 12),
        Text(
          'Looking for Git on this computer…',
          style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}

/// The card's body once the probe has answered: a heading, a sentence saying
/// which Git that is, where it lives, and the action the state calls for.
class _Status extends ConsumerWidget {
  const _Status({required this.status});

  final GitStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final theme = Theme.of(context);
    final (dot, title, detail) = switch (status) {
      GitReady(:final version, ours: false) => (
        AppPalette.online,
        'Git ${gitVersionLabel(version)}',
        'Grid is using the Git already on this computer, so your sign-in, '
            'proxy and certificates keep working as they do everywhere else.',
      ),
      GitReady(:final version, ours: true) => (
        AppPalette.online,
        'Git ${gitVersionLabel(version)}',
        'This computer had no Git of its own, so Grid fetched one. It is used '
            'inside Grid only — nothing else on the computer changed.',
      ),
      GitTooOld(:final version) => (
        AppPalette.warn,
        'Git ${gitVersionLabel(version)} is too old',
        'Grid needs ${kMinimumGitVersion.major}.${kMinimumGitVersion.minor} or '
            'newer. It can fetch its own copy and use that inside Grid, '
            'leaving yours where it is.',
      ),
      // Never "too old": this Git may be newer than the floor and still not
      // sign in, and a user sent to upgrade would install what they have. Say
      // which copy it is and where it lives — on the machine this was found on,
      // an old one at /usr/local/bin was hiding a newer one at /usr/bin, and the
      // path is the only part of this that points at the fix.
      GitCannotCarryCredential(:final version, :final path) => (
        AppPalette.warn,
        "Git ${gitVersionLabel(version)} can't sign in to your grid",
        'The Git at $path can\'t carry Grid\'s sign-in, so getting a copy of a '
            'project would fail. Grid can fetch its own copy and use that '
            'inside Grid, leaving yours where it is.',
      ),
      GitMissing() => (
        AppPalette.offline,
        'No Git on this computer',
        'Grid fetches one in the background the first time you sign in. That '
            "hasn't finished here — you can start it now.",
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              // Optically centred on the title's first line rather than its box.
              padding: const EdgeInsets.only(top: 6),
              child: StatusDot(color: dot, size: 8),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            _Action(status: status),
          ],
        ),
        if (status
            case GitReady(:final path) ||
                GitTooOld(:final path) ||
                GitCannotCarryCredential(:final path)) ...[
          const SizedBox(height: 12),
          _Where(path: path),
        ],
        const _Failure(),
        if (status is GitMissing) const _NoBuildHere(),
      ],
    );
  }
}

/// The Git being run, spelled out. Selectable because the one thing someone
/// checks here is *which* Git — and the answer is a path they'll want to paste
/// into a terminal.
class _Where extends StatelessWidget {
  const _Where({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: SelectableText(
          path,
          style: TextStyle(
            fontFamily: AppFont.mono,
            fontSize: 12,
            color: AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Install, or look again — never both, and nothing at all when Git is already
/// the app's own copy and current.
class _Action extends ConsumerWidget {
  const _Action({required this.status});

  final GitStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(gitInstallProvider);
    if (install is GitInstallRunning) return _Working(step: install.step);

    final controller = ref.read(gitInstallProvider.notifier);
    // Offer the download only where there is something to download and a reason
    // to: a Git that works is left alone, and a platform with no pinned build
    // gets the notice below rather than a button that could only fail.
    final offerInstall =
        status is! GitReady && ref.watch(gitInstallerProvider).supported;
    if (offerInstall) {
      return FilledButton(
        onPressed: controller.install,
        child: const Text('Install Git'),
      );
    }

    // Otherwise the useful action is noticing a Git that changed underneath us:
    // an upgrade, a move to Homebrew's, or the one the user has just installed
    // from the command below.
    return OutlinedButton(
      onPressed: controller.recheck,
      child: const Text('Check again'),
    );
  }
}

/// It downloads, so it takes a moment — and says which moment, rather than
/// freezing a button for a minute.
class _Working extends StatelessWidget {
  const _Working({required this.step});

  final String step;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(),
        const SizedBox(width: 10),
        // Bounded: this sits beside an Expanded column, so an installer line
        // longer than expected would eat the description's width rather than
        // wrap. Ellipsis over overflow — the log has the full line either way.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            step,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Why the last install didn't work, with the way to try it again.
///
/// It outlives the attempt on purpose: the install that matters here ran in the
/// background at launch, so by the time anyone opens this screen the failure is
/// hours old and this is the only place it was ever going to be read.
class _Failure extends ConsumerWidget {
  const _Failure();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(gitInstallProvider);
    if (state is! GitInstallFailed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              state.message,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: ref.read(gitInstallProvider.notifier).install,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// The dead end: no Git here, and no build the app could fetch for this machine
/// (Windows today). Hands over the command rather than a sentence about it.
class _NoBuildHere extends ConsumerWidget {
  const _NoBuildHere();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(gitInstallerProvider).supported) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.only(top: 12),
      child: GitMissingNotice(
        message:
            "Grid has no Git build for this computer yet, so it can't fetch "
            'one for you. Install Git and press Check again.',
      ),
    );
  }
}

/// What Git is actually for here — the part that makes the row above worth a
/// screen rather than a line in a log.
///
/// Only what is true today. The branch and worktree work this section was opened
/// for isn't built, and a screen that listed it would be promising.
class _WhatItIsFor extends StatelessWidget {
  const _WhatItIsFor();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What Grid uses it for',
              style: theme.textTheme.titleSmall?.copyWith(
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Seeing what changed in a project, committing work you asked for, '
              'and downloading things the assistant is told to add. Grid never '
              'changes your Git settings, and never signs in as you.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
