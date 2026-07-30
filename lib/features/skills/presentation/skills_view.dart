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
/// One tab per assistant, because that is the unit that matters: a skill is
/// only live for an assistant whose own folder holds a copy. The app keeps its
/// own library behind the scenes to copy from, but nothing reads it, so it
/// isn't a tab.
///
/// Opening the screen always starts on Hermes. That falls out of
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
          for (final option in kSkillTabs)
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
