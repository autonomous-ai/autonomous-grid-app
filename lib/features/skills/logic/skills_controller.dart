import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/skill_writer.dart';
import 'public_skill_catalog.dart';
import 'skill_files.dart';
import 'skill_sharing.dart';

/// Which assistant's skills the screen is showing. Hermes by default — the
/// agent the app installs, points at a grid and chats through.
///
/// Auto-disposed, which is what makes "opening Skills starts on Hermes" true:
/// the pill is the screen's state and dies with it. Resetting it by hand on the
/// way in isn't an option — Riverpod refuses a write from `initState`, and
/// rightly: two widgets would read different values for one frame.
final skillSourceProvider = NotifierProvider<SkillSourceNotifier, SkillSource>(
  SkillSourceNotifier.new,
  isAutoDispose: true,
);

class SkillSourceNotifier extends Notifier<SkillSource> {
  @override
  SkillSource build() => SkillSource.hermes;

  void select(SkillSource source) => state = source;
}

/// Who gets a copy of the next skill added — asked by every add flow, answered
/// once.
///
/// Hermes by default: it's the agent the app installs, points at a grid and
/// chats through, so it's the one a skill is nearly always meant for. Kept for
/// the session rather than auto-disposed, so the answer follows the user from
/// the write dialog to the catalog.
final skillTargetProvider = NotifierProvider<SkillTargetNotifier, ShareTarget>(
  SkillTargetNotifier.new,
);

class SkillTargetNotifier extends Notifier<ShareTarget> {
  @override
  ShareTarget build() => ShareTarget.hermes;

  void select(ShareTarget target) => state = target;
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
    Directory? landed;
    final failure = await _write((writer) async {
      landed = await writer.create(
        name: name,
        description: description,
        instructions: instructions,
      );
    });
    return _landed(failure, landed);
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
    Directory? landed;
    final failure = await _write((writer) async {
      landed = await writer.import(sourcePath);
    });
    return _landed(failure, landed);
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
      Directory? landed;
      final failure = await _write((writer) async {
        // Into `public/`: this is Grid's copy of somebody else's skill, not the
        // user's work, and the Author column should say so.
        landed = await writer.import(staging.path, intoPublic: true);
      });
      return _landed(failure, landed);
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  /// What every way of adding a skill does once the store has it: show the
  /// folder it went into, and hand a copy to the agent the user picked.
  ///
  /// The hand-off failing is reported without pretending the whole thing
  /// failed — the skill *is* saved, and a message that says only "couldn't"
  /// would send the user looking for something that's already there.
  Future<String?> _landed(String? failure, Directory? dir) async {
    if (failure != null) return failure;
    if (dir == null) return null;
    // The write is done and the skill is on disk; if the screen went away while
    // it ran there is nobody left to move to its folder (see [_reread]).
    if (!ref.mounted) return null;
    final target = ref.read(skillTargetProvider);
    // Show the assistant that just got it. "All agents" has no one tab, so it
    // leaves the screen where it was.
    final landedOn = target.agents.length == 1
        ? skillFolderOf(target.agents.single)
        : null;
    if (landedOn != null) {
      ref.read(skillSourceProvider.notifier).select(landedOn);
    }
    try {
      await ref.read(skillSharerProvider).shareFolder(dir.path, target.agents);
    } on Object catch (error) {
      return 'Saved, but couldn\'t give it to ${target.label}: $error';
    } finally {
      _changed();
      // Re-read *after* the copy lands. Switching to the agent's tab above
      // starts a read of that folder while the copy is still being written, so
      // without this the screen arrives on the right tab and shows everything
      // except the skill just added — exactly the "it vanished" this landing
      // exists to prevent.
      await _refreshList();
    }
    return null;
  }

  /// Re-read whatever folder the screen is on now. For the changes that don't
  /// go through [_write] — a copy handed to an agent — where the folder on
  /// screen may also have changed in between.
  Future<void> _refreshList() async {
    if (!ref.mounted) return;
    final plane = _plane;
    if (plane == null) return;
    await _reread(plane, _source);
  }

  /// Undo an install: take the skill away from the assistants currently
  /// selected, and remove the store copy that fed them.
  ///
  /// The mirror of [installPublic], which puts it in both places. The store
  /// copy is found by folder name in the store itself rather than in whatever
  /// list the screen is showing — the catalog can be open over Hermes's folder,
  /// and deleting from *that* is neither allowed nor what was asked.
  Future<String?> uninstallPublic(PublicSkill skill) async {
    final plane = _plane;
    if (plane == null) return _noSkills;
    final target = ref.read(skillTargetProvider);
    try {
      await ref
          .read(skillSharerProvider)
          .unshareFolder(skill.slug, target.agents);
    } on Object catch (error) {
      return "Couldn't take ${skill.name} off ${target.label}: $error";
    }

    final copies = (await plane.list(SkillSource.store))
        .where((installed) => installed.path.split('/').last == skill.slug)
        .toList();
    final failure = copies.isEmpty
        ? null
        : await _write((writer) async {
            for (final copy in copies) {
              await writer.delete(copy.path);
            }
          });
    _changed();
    return failure;
  }

  Future<String?> delete(AgentSkill skill) async {
    final failure = await _write((writer) => writer.delete(skill.path));
    if (failure == null) _changed();
    return failure;
  }

  /// Hand a copy of [skill] to an agent's own folder.
  ///
  /// Doesn't touch the store, so the list itself doesn't change — only the
  /// record of who has what, which the rows draw their tags from.
  Future<String?> share(AgentSkill skill, ShareTarget target) async {
    try {
      await ref.read(skillSharerProvider).share(skill, target);
    } on ArgumentError catch (error) {
      return '${error.message}';
    } on Object catch (error) {
      return "Couldn't share ${skill.name}: $error";
    }
    _changed();
    return null;
  }

  /// Re-read which assistant holds what. There is no record to keep in step —
  /// the folders are the record — so this is the whole of it. A no-op once this
  /// notifier is gone: the folders are still right, and there is no list left
  /// to redraw (see [_reread]).
  void _changed() {
    if (ref.mounted) ref.invalidate(agentSkillNamesProvider);
  }

  /// Rewrite the skills Grid ships for this agent and re-read the folder.
  /// Idempotent — also the fix for a skill deleted by mistake.
  Future<String?> reinstallGridSkills() async {
    final plane = _plane;
    if (plane == null) return _noSkills;
    final source = _source;
    try {
      await plane.installGridSkills();
    } on Object catch (error) {
      return "Couldn't install Grid's skills: $error";
    }
    await _reread(plane, source);
    return null;
  }

  /// Run one write and re-read the list. Failures come back as a message rather
  /// than an exception: every caller is a button, and a button needs something
  /// to say.
  Future<String?> _write(Future<void> Function(SkillWriter) action) async {
    final plane = _plane;
    final writer = plane?.writer;
    if (plane == null || writer == null) return _noSkills;
    // Read the folder before the first await. This notifier is auto-disposed,
    // and a write outlives it easily — the screen closed on a save, the pill
    // switched — after which a Ref throws rather than answering.
    final source = _source;
    try {
      // Close the old shortcut first: an agent still reading the library would
      // pick this skill up without anyone giving it to them.
      await plane.detachLibrary();
      await action(writer);
    } on AgentExtensionException catch (error) {
      return error.message;
    } on ArgumentError catch (error) {
      // The writer's own refusals — a folder that isn't a skill, a name already
      // taken — are written for the user. Wrapping them in "Couldn't save" only
      // buries the sentence that says what to do. The raw error, path included,
      // still goes to the log: a sentence the user just read diagnoses nothing
      // on its own (§6).
      _log('refused a skill write: $error');
      return '${error.message}';
    } on Object catch (error) {
      _log('a skill write failed: $error');
      return "Couldn't save the skill: $error";
    }
    await _reread(plane, source);
    return null;
  }

  /// Re-read [source] into [state] after a write that changed it.
  ///
  /// Silently does nothing once this notifier is gone: the write itself
  /// succeeded, and there is no longer a screen to show the new list on. Left
  /// unguarded, a save the user closed the screen on threw instead — a Ref
  /// after dispose — and took the turn down with it.
  Future<void> _reread(AgentSkillsPlane plane, SkillSource source) async {
    final skills = await plane.list(source);
    if (!ref.mounted) return;
    state = AsyncData(skills);
  }

  /// Best-effort diagnostics — skipped once this notifier is gone, like every
  /// other Ref read here.
  void _log(String line) {
    if (ref.mounted) ref.read(appLogProvider).warn('skills', line);
  }

  /// The folder the screen is on right now. Read, never watched: a re-read
  /// after a write refreshes what the user is looking at, and switching folders
  /// is already a rebuild.
  SkillSource get _source => ref.read(skillSourceProvider);

  static const _noSkills = "This agent doesn't support editing skills here.";
}
