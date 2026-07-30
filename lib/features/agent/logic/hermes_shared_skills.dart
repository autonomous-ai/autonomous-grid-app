import '../../../infrastructure/cli/hermes_config_file.dart';

/// The literal entry written into `skills.external_dirs` — home-relative on
/// purpose: Hermes expands `~` itself, so the config stays valid if the home
/// directory moves with a new username.
const String kSharedSkillsExternalDir = '~/.grid/skills';

/// Merge the app's skills store into Hermes's `skills.external_dirs` —
/// append-if-absent, never clobbering entries the user set by hand. Hermes
/// tolerates a bare string where a list is expected, so both shapes are read.
///
/// Every skill the app manages now lives outside `~/.hermes`, so this is no
/// longer a nicety: without the entry, Hermes reads none of them. Both writers
/// call it — the authoring path before a skill lands, the installer before the
/// public ones do — so neither can leave a skill in a folder the agent doesn't
/// read. Idempotent.
Future<void> projectSharedSkillsStore(HermesConfigFile config) async {
  final existing = await config.valueAt(['skills', 'external_dirs']);
  final dirs = switch (existing) {
    final List list => [for (final entry in list) entry.toString()],
    final String single => [single],
    _ => <String>[],
  };
  if (dirs.contains(kSharedSkillsExternalDir)) return;
  await config.edit((editor) {
    HermesConfigFile.upsert(editor, ['skills', 'external_dirs'], [
      ...dirs,
      kSharedSkillsExternalDir,
    ]);
  });
}
