import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/skills_controller.dart';
import 'widgets/new_skill_dialog.dart';
import 'widgets/skill_list.dart';

/// The skills installed for the assistant — instructions for one job ("make an
/// image on the grid", "write my weekly report"), yours first, read from
/// what's really on disk rather than a list the app keeps.
class SkillsView extends ConsumerWidget {
  const SkillsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExtensionScreen(
      title: 'Skills',
      subtitle:
          'Teach the assistant one job in your own words — it reaches for a '
          'skill when a chat calls for it.',
      searchHint: 'Search skills',
      createLabel: 'Write a skill',
      onCreate: showNewSkillDialog,
      onRefresh: () => ref.invalidate(skillsProvider),
      listBuilder: (context, {required filtered, required matches}) {
        return switch (ref.watch(skillsProvider)) {
          AsyncData(:final value) => SkillList(
            filtered: filtered,
            skills: [
              for (final skill in value)
                if (matches(skill.name, skill.description)) skill,
            ],
          ),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read the installed skills: $error",
          ),
          _ => const ExtensionLoadingRows(),
        };
      },
    );
  }
}
