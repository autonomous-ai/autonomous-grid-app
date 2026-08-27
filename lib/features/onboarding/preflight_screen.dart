import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_environment.dart';
import '../../infrastructure/providers.dart';
import '../../shared/widgets/error_box.dart';
import 'preflight_providers.dart';
import 'preflight_report.dart';
import 'preflight_widgets.dart';

/// The one-liner that installs the `grid` background helper — pointed at prod in
/// release, at the staging site in dev (see [AppEnvironment.websiteUrl]).
String get _installCommand =>
    'curl -fsSL ${AppEnvironment.websiteUrl}/install.sh | bash';

/// Shown when the app can't use `grid`. Each [PreflightIssue] gets its own
/// headline, explanation and next step: a Mac holding the wrong download is
/// told to get the right one, not handed an install command that fixes a
/// problem it doesn't have.
class PreflightScreen extends ConsumerWidget {
  const PreflightScreen({super.key, required this.issue});

  final PreflightIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(_title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(_message, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              PreflightCheckRow(label: _checkLabel),
              _IssueDetail(issue: issue),
              const SizedBox(height: 24),
              _Actions(issue: issue),
            ],
          ),
        ),
      ),
    );
  }

  String get _title => switch (issue) {
    GridMissing() => 'Grid needs setup',
    GridWrongArch() => 'This copy of Grid is for a different Mac',
    GridUnusable() => "Grid couldn't start its background helper",
  };

  String get _message => switch (issue) {
    GridMissing() =>
      'Grid needs its background helper installed before it can run. Install '
          'it using the steps below, then check again.',
    GridWrongArch() =>
      "The helper inside this download is built for a different Mac processor "
          'than this one, so it never starts. Download the version for this '
          'Mac, replace the app, and open it again.',
    GridUnusable() =>
      'The helper is installed but it stopped before it could answer. Fix the '
          'issue below, then check again.',
  };

  String get _checkLabel => switch (issue) {
    GridMissing() => 'Grid background helper',
    GridWrongArch() => 'Grid background helper — wrong Mac processor',
    GridUnusable() => "Grid background helper — didn't run",
  };
}

/// The per-issue block between the check row and the buttons: an install
/// command when there is nothing to run, the raw failure when there is.
class _IssueDetail extends StatelessWidget {
  const _IssueDetail({required this.issue});

  final PreflightIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (issue) {
      GridMissing() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Text('Install it', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'On macOS or Linux, run this in a terminal:',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          InstallCommand(command: _installCommand),
        ],
      ),
      // Nothing to add: the message already says to download the right build,
      // and the button below opens the page that has it.
      GridWrongArch() => const SizedBox.shrink(),
      GridUnusable(:final message) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: ErrorBox(message: message),
      ),
    };
  }
}

/// The buttons under the explanation. "Check again" re-runs the whole check;
/// the second one leads to whatever would actually fix this case.
class _Actions extends ConsumerWidget {
  const _Actions({required this.issue});

  final PreflightIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recheck = FilledButton.icon(
      onPressed: () {
        // Re-resolve first: on a machine where `grid` was just installed, the
        // cached resolution is what says "not found", so re-running preflight
        // alone would report the same thing forever.
        ref.invalidate(gridResolutionProvider);
        ref.invalidate(preflightProvider);
      },
      icon: const Icon(Icons.refresh),
      label: const Text('Check again'),
    );
    final download = OutlinedButton.icon(
      onPressed: () => launchUrl(
        Uri.parse(AppEnvironment.downloadsUrl),
        mode: LaunchMode.externalApplication,
      ),
      icon: const Icon(Icons.download_outlined, size: 18),
      label: const Text('Open the download page'),
    );
    // Wrong build: getting the right one is the fix, so it leads.
    final children = issue is GridWrongArch
        ? [download, const SizedBox(width: 12), recheck]
        : [recheck, const SizedBox(width: 12), download];
    return Row(children: children);
  }
}
