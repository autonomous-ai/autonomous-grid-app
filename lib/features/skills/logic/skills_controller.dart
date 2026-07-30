import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/skill_writer.dart';
import 'public_skill_catalog.dart';
import 'skill_files.dart';
import 'skill_sharing.dart';

/// Which folder of skills the screen is showing. The app's own store by
/// default — the one place the user's work lives, and the only one they can
/// change from here.
///
/// Auto-disposed, which is what makes "opening Skills starts on Shared" true:
/// the pill is the screen's state and dies with it. Resetting it by hand on the
/// way in isn't an option — Riverpod refuses a write from `initState`, and
/// rightly: two widgets would read different values for one frame.
final skillSourceProvider = NotifierProvider<SkillSourceNotifier, SkillSource>(
  SkillSourceNotifier.new,
  isAutoDispose: true,
);

class SkillSourceNotifier extends Notifier<SkillSource> {
  @override
  SkillSource build() => SkillSource.shared;

  void select(SkillSource source) => state = source;
}

/// The skills in the selected source, read straight from the agent's skills
/// plane — the app keeps no second list, so the screen and the agent can't
/// disagree.
///
/// Every change writes through the plane's [SkillWriter] and re-reads, which is
/// what the plugin and MCP lists already do; skills used to be the odd one out,
/// with widgets writing through a bare author and hand-invalidating the read
/// provider in three places.
/// Auto-disposed alongside [skillSourceProvider] — it reads the folder that
/// provider names, so outliving it would mean showing one folder's skills under
/// another's pill. A fresh scan on re-entry is also the honest answer: the
/// folders change without the app's help.
final skillsProvider =
    AsyncNotifierProvider<SkillsController, List<AgentSkill>>(
      SkillsController.new,
      isAutoDispose: true,
    );

/// What's in the app's own store, whichever folder the screen happens to be
/// showing.
///
/// The catalog needs this and [skillsProvider] can't answer it: open the
/// catalog while reading Hermes's folder and "is this installed?" would be
/// asked of the wrong list. Re-read whenever the screen's list changes, since
/// every write goes through that.
final storedSkillsProvider = FutureProvider.autoDispose<List<AgentSkill>>((
  ref,
) async {
  final tool = ref.watch(extensionAgentProvider);
  final plane = ref.watch(agentExtensionsProvider(tool))?.skills;
  ref.watch(skillsProvider);
  return await plane?.list(SkillSource.shared) ?? const [];
});

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
    final source = ref.watch(skillSourceProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.skills;
    return plane?.list(source) ?? Future.value(const []);
  }

  AgentSkillsPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.skills;
  }

  /// Write a new skill — always into the app's store, whichever folder the
  /// screen happens to be showing — and land the user on it, so a skill written
  /// while reading Hermes's list doesn't look like it vanished.
  Future<String?> create({
    required String name,
    required String description,
    required String instructions,
  }) async {
    final failure = await _write(
      (writer) => writer.create(
        name: name,
        description: description,
        instructions: instructions,
      ),
    );
    if (failure == null) {
      ref.read(skillSourceProvider.notifier).select(SkillSource.shared);
    }
    return failure;
  }

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

  /// Take a folder the user picked and copy it in as a skill, then show it —
  /// same landing as [create], for the same reason.
  Future<String?> importFolder(String sourcePath) async {
    final failure = await _write((writer) => writer.import(sourcePath));
    if (failure == null) {
      ref.read(skillSourceProvider.notifier).select(SkillSource.shared);
    }
    return failure;
  }

  /// Install one of the skills the app ships with.
  ///
  /// Laid down in a temp folder first and then imported like any other folder,
  /// so a catalog skill goes through the same check and the same writer as one
  /// the user dropped in — there is one way into the store, not two.
  Future<String?> installPublic(PublicSkill skill) async {
    final Directory staging;
    try {
      staging = await Directory.systemTemp.createTemp('grid_public_skill');
      await writePublicSkillTo(
        ref.read(publicSkillBundleProvider),
        skill,
        staging,
      );
    } on Object catch (error) {
      return "Couldn't unpack ${skill.name}: $error";
    }
    try {
      final failure = await _write(
        // Into `public/`: this is Grid's copy of somebody else's skill, not the
        // user's work, and the Author column should say so.
        (writer) => writer.import(staging.path, intoPublic: true),
      );
      if (failure == null) {
        ref.read(skillSourceProvider.notifier).select(SkillSource.shared);
      }
      return failure;
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  /// Take a catalog skill back out of the store.
  ///
  /// Found by folder name in the store rather than in whatever the screen is
  /// showing — the catalog can be open over Hermes's folder, and deleting from
  /// *that* list is both refused and not what was asked.
  Future<String?> uninstallPublic(PublicSkill skill) async {
    final plane = _plane;
    if (plane == null) return _noSkills;
    final stored = await plane.list(SkillSource.shared);
    final copies = stored
        .where((installed) => installed.path.split('/').last == skill.slug)
        .toList();
    if (copies.isEmpty) return '${skill.name} is not installed.';
    return _write((writer) async {
      for (final copy in copies) {
        await writer.delete(copy.path);
      }
    });
  }

  Future<String?> delete(AgentSkill skill) =>
      _write((writer) => writer.delete(skill.path));

  /// Hand a copy of [skill] to an agent's own folder.
  ///
  /// Doesn't touch the store, so nothing on screen changes — the list is not
  /// re-read, and the toast is the whole feedback.
  Future<String?> share(AgentSkill skill, ShareTarget target) async {
    try {
      await ref.read(skillSharerProvider).share(skill, target);
    } on ArgumentError catch (error) {
      return '${error.message}';
    } on Object catch (error) {
      return "Couldn't share ${skill.name}: $error";
    }
    return null;
  }

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
    state = AsyncData(await plane.list(_source));
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
    } on ArgumentError catch (error) {
      // The writer's own refusals — a folder that isn't a skill, a name already
      // taken — are written for the user. Wrapping them in "Couldn't save" only
      // buries the sentence that says what to do.
      return '${error.message}';
    } on Object catch (error) {
      return "Couldn't save the skill: $error";
    }
    state = AsyncData(await plane.list(_source));
    return null;
  }

  /// The folder the screen is on right now. Read, never watched: a re-read
  /// after a write refreshes what the user is looking at, and switching folders
  /// is already a rebuild.
  SkillSource get _source => ref.read(skillSourceProvider);

  static const _noSkills = "This agent doesn't support editing skills here.";
}
