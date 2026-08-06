import 'package:flutter/material.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';

/// Running / succeeded / failed, as one glyph. Shared with the detail dialog so
/// a row and the panel it opens can never disagree about how a command ended.
class LogStatusIcon extends StatelessWidget {
  const LogStatusIcon({super.key, required this.status});

  final CliCallStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette.online — follow theme flips.
    return switch (status) {
      CliCallStatus.running => const AppSpinner(),
      CliCallStatus.success => Icon(
        Icons.check_circle,
        size: 16,
        color: AppPalette.online,
      ),
      CliCallStatus.failed => Icon(
        Icons.error,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}

/// The kind, the clock time, and how it ended — the trailing column of a row.
