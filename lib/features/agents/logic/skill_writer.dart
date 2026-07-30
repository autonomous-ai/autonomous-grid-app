import 'dart:io';

/// The authoring half of an agent's skills plane: create, reread, rewrite and
/// delete the skills the user writes in the app.
///
/// Kept apart from listing (see `AgentSkillsPlane`) because an agent can be
/// able to show its skills without it being safe to author into its folder —
/// such an agent exposes a `null` writer and the Skills screen goes read-only.
abstract interface class SkillWriter {
  /// True when a skill of this name is already there — the dialog checks first
  /// rather than silently overwriting someone's work.
  bool exists(String name);

  /// Create the skill and return its folder.
  Future<Directory> create({
    required String name,
    required String description,
    required String instructions,
  });

  /// Take a folder that is already a skill and copy it in whole — card,
  /// scripts, assets and all — returning where it landed.
  ///
  /// Separate from [create] because nothing here is authored: the folder
  /// arrives finished, and what it needs is checking rather than writing. A
  /// folder that isn't a skill is rejected before anything is copied.
  ///
  /// [intoPublic] files it under the store's public folder instead of the
  /// user's own — for a skill taken from the shipped catalog, which is not the
  /// user's work and shouldn't claim to be.
  Future<Directory> import(String sourcePath, {bool intoPublic});

  /// The instructions currently in a skill, read back so the editor can
  /// pre-fill them instead of starting blank.
  Future<String> readInstructions(String path);

  /// Rewrite the skill whose folder is [previousPath], in place — an edit must
  /// never silently move a skill between folders. When the name changes the
  /// folder moves with it *within that folder*, and the old one is removed:
  /// otherwise a rename would leave a stale duplicate the agent would still
  /// read.
  ///
  /// Keyed by path rather than by name because a name doesn't say where the
  /// skill is: the store has more than one folder, and the app can't assume it
  /// wrote the one being edited.
  Future<Directory> edit({
    required String previousPath,
    required String name,
    required String description,
    required String instructions,
  });

  /// Delete a skill's folder. Implementations guard against a path outside
  /// their skills tree, so a bad `path` can never take out something it
  /// shouldn't.
  Future<void> delete(String path);
}
