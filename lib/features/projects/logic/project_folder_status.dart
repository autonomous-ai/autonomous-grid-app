import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'project.dart';

/// What the app says about a project whose folder isn't on this computer any
/// more. One sentence, shared by everywhere that reports it — the rail card and
/// the projects list each carried their own hand-typed copy.
const projectFolderMissingMessage = "This folder isn't there any more.";

/// The same thing said where it *stops* something — a turn that can't be sent
/// because the folder it would run in is gone.
///
/// Names the path and the way out. The failure the user saw before this existed
/// was "Couldn't start Claude Code on this computer", which is what a spawn into
/// a missing working directory reports: true, useless, and pointing at the agent
/// rather than at the folder that actually went away.
String projectFolderGoneMessage(String path) =>
    "This project's folder isn't there any more: $path\n"
    'Point the project at another folder from its "…" menu, or start the chat '
    'outside the project.';

/// How long one folder gets to answer. A path on a share that has gone away
/// doesn't answer at all, and one dead mount must not hold up the answer for the
/// folders that are right here.
const _probeTimeout = Duration(seconds: 5);

/// Whether a folder is on this computer. A function so tests can answer without
/// a filesystem.
typedef FolderProbe = Future<bool> Function(String path);

Future<bool> _folderOnDisk(String path) => Directory(path).exists();

/// Overridable so tests never stat a real path.
final folderProbeProvider = Provider<FolderProbe>((ref) => _folderOnDisk);

/// The project folders that aren't on this computer.
///
/// A project whose folder was moved or deleted stays in the list and is shown as
/// missing rather than dropped — dropping it would take the chats that belong to
/// it too.
///
/// `Directory.existsSync()` is a blocking stat. On a local disk it costs
/// microseconds, which is why it used to sit in four `build()` methods; on a
/// network share or a drive that's been unplugged it can hold the UI thread for
/// *seconds* — and it was holding it for a badge. The same stat, awaited here,
/// costs the frame nothing.
///
/// Checked once per project list, then again whenever the app is brought back to
/// the front ([revalidateProjectFolders]) — folders are moved and deleted in
/// Finder, which is exactly where the user was while this window sat behind it.
/// That beats polling the disk all day for a badge, and it re-checks at the one
/// moment the answer can have changed. A path that doesn't answer within
/// [_probeTimeout] is *not* called missing — see [watchProjectMissing].
final missingProjectFoldersProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) {
  final probe = ref.watch(folderProbeProvider);
  return _missingAmong({
    for (final project in ref.watch(projectsProvider)) project.path,
  }, probe);
});

/// Ask the folders again. Called when the app regains focus, since a folder can
/// only have gone missing while the user was somewhere else.
void revalidateProjectFolders(WidgetRef ref) =>
    ref.invalidate(missingProjectFoldersProvider);

/// Whether [path] is gone, asked once for a single folder — what the send path
/// checks before starting an agent in it.
///
/// Same probe and the same rule as the badge above, silence included: a share
/// that has stopped answering must not turn into "your folder is gone" on the
/// one screen where that sentence blocks the turn.
Future<bool> projectFolderMissing(Ref ref, String path) async {
  final (_, onDisk) = await _probeOne(path, ref.read(folderProbeProvider));
  return !onDisk;
}

/// Which of [paths] came back missing, all asked at once — a folder on a slow
/// share shouldn't queue behind the ones on the internal disk.
Future<Set<String>> _missingAmong(Set<String> paths, FolderProbe probe) async {
  final answers = await Future.wait([
    for (final path in paths) _probeOne(path, probe),
  ]);
  return {
    for (final (path, onDisk) in answers)
      if (!onDisk) path,
  };
}

/// One folder's answer, with silence counting as *present*: a share that has
/// stopped answering is the app's problem to wait out, not the user's folder
/// gone, and telling them their work has disappeared because a stat was slow is
/// the worse of the two lies.
Future<(String, bool)> _probeOne(String path, FolderProbe probe) async {
  try {
    return (path, await probe(path).timeout(_probeTimeout));
  } on Object {
    return (path, true);
  }
}

/// Whether [project]'s folder has gone missing, read the way the UI must read
/// it: a folder is called missing only once a check has come back saying so.
///
/// Before the first answer it reads as present, so opening the app never flashes
/// a false [projectFolderMissingMessage] over every project. The badge landing a
/// frame late is the whole trade for not blocking the frame.
bool watchProjectMissing(WidgetRef ref, Project project) => ref.watch(
  missingProjectFoldersProvider.select(
    (missing) => missing.value?.contains(project.path) ?? false,
  ),
);
