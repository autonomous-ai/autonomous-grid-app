import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/skills/agent_skill_home.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/skills_controller.dart';
import 'widgets/add_skill_menu.dart';
import 'widgets/skill_list.dart';

/// The skills installed for the assistant — instructions for one job ("make an
/// image on the grid", "write my weekly report"), yours first, read from
/// what's really on disk rather than a list the app keeps.
///
/// Three folders hold them and the pills switch between: the app's own store,
/// then each agent's private one. Only the store is the app's to change, so the
/// other two read as a window onto what the agent already knows.
///
/// Opening the screen always starts on Shared — the folder the user's own work
/// is in, and the only one they can do anything about. That falls out of
/// [skillSourceProvider] being auto-disposed with this screen rather than being
/// reset here: a write from a widget life-cycle is exactly what Riverpod
/// forbids.
class SkillsView extends ConsumerWidget {
  const SkillsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(skillSourceProvider);
    return ExtensionScreen(
      title: 'Skills',
      subtitle:
          'Teach the assistant one job in your own words — it reaches for a '
          'skill when a chat calls for it.',
      searchHint: 'Search skills',
      // Two ways to get a skill — write one, or bring a folder — so the button
      // opens a menu instead of going straight to the form.
      createButton: const AddSkillButton(),
      onRefresh: () => ref.invalidate(skillsProvider),
      filterBar: Row(
        children: [
          for (final option in SkillSource.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChoice(
                label: Text(option.label),
                selected: option == source,
                onTap: () =>
                    ref.read(skillSourceProvider.notifier).select(option),
              ),
            ),
        ],
      ),
      listBuilder: (context, {required filtered, required matches}) {
        return switch (ref.watch(skillsProvider)) {
          AsyncData(:final value) => SkillList(
            filtered: filtered,
            source: source,
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
