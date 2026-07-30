import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/skill_writer.dart';

/// The skills installed for the selected agent, read straight from its skills
/// plane — the app keeps no second list, so the screen and the agent can't
/// disagree.
///
/// Every change writes through the plane's [SkillWriter] and re-reads, which is
/// what the plugin and MCP lists already do; skills used to be the odd one out,
/// with widgets writing through a bare author and hand-invalidating the read
/// provider in three places.
final skillsProvider =
    AsyncNotifierProvider<SkillsController, List<AgentSkill>>(
      SkillsController.new,
    );

/// The selected agent's authoring surface, or null when it can only display
/// skills — dialogs read this for pre-checks (does a name exist, what were the
/// instructions) while every write goes through [SkillsController].
final skillWriterProvider = Provider<SkillWriter?>((ref) {
  final tool = ref.watch(extensionAgentProvider);
  return ref.watch(agentExtensionsProvider(tool))?.skills?.writer;
});

class SkillsController extends AsyncNotifier<List<AgentSkill>> {
  @override
  Future<List<AgentSkill>> build() {
    final tool = ref.watch(extensionAgentProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.skills;
    return plane?.list() ?? Future.value(const []);
  }

  AgentSkillsPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.skills;
  }

  Future<String?> create({
    required String name,
    required String description,
    required String instructions,
  }) => _write(
    (writer) => writer.create(
      name: name,
      description: description,
      instructions: instructions,
    ),
  );

  Future<String?> edit({
    required String previousPath,
    required String name,
    required String description,
    required String instructions,
  }) => _write(
    (writer) => writer.edit(
      previousPath: previousPath,
      name: name,
      description: description,
      instructions: instructions,
    ),
  );

  Future<String?> delete(AgentSkill skill) =>
      _write((writer) => writer.delete(skill.path));

  /// Rewrite the skills Grid ships for this agent and re-read the folder.
  /// Idempotent — also the fix for a skill deleted by mistake.
  Future<String?> reinstallGridSkills() async {
    final plane = _plane;
    if (plane == null) return _noSkills;
    try {
      await plane.installGridSkills();
    } on Object catch (error) {
      return "Couldn't install Grid's skills: $error";
    }
    state = AsyncData(await plane.list());
    return null;
  }

  /// Run one write and re-read the list. Failures come back as a message rather
  /// than an exception: every caller is a button, and a button needs something
  /// to say.
  Future<String?> _write(Future<void> Function(SkillWriter) action) async {
    final plane = _plane;
    final writer = plane?.writer;
    if (plane == null || writer == null) return _noSkills;
    try {
      // Point the agent at the shared store before anything lands in it — a
      // skill written into a folder the agent doesn't read isn't a skill.
      await plane.projectSharedStore();
      await action(writer);
    } on AgentExtensionException catch (error) {
      return error.message;
    } on Object catch (error) {
      return "Couldn't save the skill: $error";
    }
    state = AsyncData(await plane.list());
    return null;
  }

  static const _noSkills = "This agent doesn't support editing skills here.";
}
