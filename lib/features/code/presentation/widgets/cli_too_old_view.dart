import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/section_scaffold.dart';

/// The grid tool on this computer has no shared-project commands.
///
/// Shown instead of letting every action fail: the tool's own answer to an
/// unknown command is a list of every command it *does* have, which reads as
/// though something is broken rather than out of date.
///
/// **No version number is quoted here**, deliberately: the commands arrived
/// without one changing, so a number would be a claim this app cannot check.
/// What it does know is that this build answers `grid task --help` with a
/// refusal, and that is what it says.
class CliTooOldView extends StatelessWidget {
  const CliTooOldView({super.key});

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SectionScaffold(
      title: 'Code',
      subtitle: 'Hand coding work to your team’s grid.',
      child: EmptyState(
        icon: LucideIcons.refreshCw300,
        title: 'This computer’s grid tool is out of date',
        message:
            'Shared projects and tasks came with a newer version of the grid '
            'tool than the one installed here. Everything else in the app '
            'keeps working — update the tool and this screen comes to life.',
        action: Text(
          'Ask whoever set this computer up to update the grid tool.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
        ),
      ),
    );
  }
}
