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

  /// The instructions currently in a skill, read back so the editor can
  /// pre-fill them instead of starting blank.
  Future<String> readInstructions(String path);

  /// Rewrite one of the user's own skills. When the name changes the folder
  /// moves with it, so the old one is removed — otherwise a rename would leave
  /// a stale duplicate the agent would still read.
  Future<Directory> edit({
    required String previousSlug,
    required String name,
    required String description,
    required String instructions,
  });

  /// Delete a skill's folder. Implementations guard against a path outside
  /// their skills tree, so a bad `path` can never take out something it
  /// shouldn't.
  Future<void> delete(String path);
}
