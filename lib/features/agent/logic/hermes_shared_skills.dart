import '../../../infrastructure/cli/hermes_config_file.dart';

/// The entry the app used to add to Hermes's `skills.external_dirs`, pointing
/// it at `~/.grid/skills`.
///
/// Kept only so it can be taken out again. It is not written any more.
const String kSharedSkillsExternalDir = '~/.grid/skills';

/// Take the app's library back out of Hermes's `skills.external_dirs`.
///
/// The library is the app's own, not an agent's: a skill reaches an assistant
/// as a copy in that assistant's folder, chosen deliberately, and nowhere else.
/// While that entry was in the config Hermes read the whole library as well —
/// so every skill in it was live for Hermes whether or not anyone had given it
/// to Hermes, and the copies the app *did* make sat beside the originals as
/// duplicate skills of the same name.
///
/// Removing the entry is not enough to do once at release: an older build may
/// have written it, and this build must undo that on whatever machine it lands
/// on. So it runs from the same two places the projection used to, and does
/// nothing when the entry is already gone. Entries the user added by hand are
/// left exactly where they are.
Future<void> unprojectSharedSkillsStore(HermesConfigFile config) async {
  final existing = await config.valueAt(['skills', 'external_dirs']);
  final dirs = switch (existing) {
    final List list => [for (final entry in list) entry.toString()],
    final String single => [single],
    _ => <String>[],
  };
  if (!dirs.contains(kSharedSkillsExternalDir)) return;
  final kept = [
    for (final dir in dirs)
      if (dir != kSharedSkillsExternalDir) dir,
  ];
  await config.edit((editor) {
    HermesConfigFile.upsert(editor, ['skills', 'external_dirs'], kept);
  });
}
