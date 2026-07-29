import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/section_scaffold.dart';

/// The agent isn't on this computer, so there's nothing to extend yet — shown
/// by every extension screen (Skills, Connectors, Plugins) in place of its
/// list, with the screen's own title so the sidebar selection still matches.
class NoAgentView extends ConsumerWidget {
  const NoAgentView({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: title,
      subtitle: subtitle,
      child: EmptyState(
        icon: Icons.extension_off_outlined,
        title: 'No assistant on this computer',
        message:
            "This computer isn't set up to answer chats yet, so it has "
            'nothing to extend.',
        action: FilledButton(
          onPressed: () => ref
              .read(shellSectionProvider.notifier)
              .select(ShellSection.engines),
          child: const Text('Set up this computer'),
        ),
      ),
    );
  }
}
