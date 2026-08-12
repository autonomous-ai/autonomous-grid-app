/// Every `grid project …` / `grid task …` command line the app builds, in one
/// pure place.
///
/// The CLI's own rule is that flags are per-subcommand and a wrong one fails
/// exactly like work that never ran — `codex exec` taking `--sandbox` while
/// `codex exec resume` rejects the whole invocation is the case that cost a
/// session. So argv is built by functions with no I/O in them, and `test/code/`
/// proves each one without spawning anything.
///
/// `--grid` is passed on every call rather than left to the active grid: the
/// app lets the user switch grids while a screen is open, and a command that
/// silently follows `~/.grid/state.json` would act on a different one than the
/// screen is showing.
library;

import 'dart:io' show Platform;

/// `--json` on every command: the app parses stdout here, unlike the lifecycle
/// calls elsewhere that only read an exit code.
const _json = '--json';

List<String> _grid(String grid) => ['--grid', grid, _json];

/// `grid project list` — every project this account is a member of, not only
/// the ones it owns.
List<String> projectListArgs({required String grid}) => [
  'project',
  'list',
  ..._grid(grid),
];

/// `grid project create --name <name>` — create-or-get by name, so running it
/// twice is not an error.
List<String> projectCreateArgs({required String name, required String grid}) =>
    ['project', 'create', '--name', name, ..._grid(grid)];

/// `grid project status <id>` — the trunk, this member's branch, the distance
/// between them, and what holds their one task slot.
List<String> projectStatusArgs({
  required String projectId,
  required String grid,
}) => ['project', 'status', projectId, ..._grid(grid)];

/// `grid project check <id>` — what integrating *would* do. A pure read: it
/// moves no ref, creates no task and holds no slot, so it answers even while a
/// task is in flight, which is exactly when `integrate` refuses.
List<String> projectCheckArgs({
  required String projectId,
  required String grid,
}) => ['project', 'check', projectId, ..._grid(grid)];

/// `grid project integrate <id>` — bring `main` into this member's own branch.
/// Takes no member key: the relay holds *the caller's* task slot while it works.
List<String> projectIntegrateArgs({
  required String projectId,
  required String grid,
}) => ['project', 'integrate', projectId, ..._grid(grid)];

/// `grid project promote <id> <member_key>` — move `main` to that member's
/// branch, fast-forward only. The key is positional and names *whose* branch,
/// which is why any member can release a colleague's work.
List<String> projectPromoteArgs({
  required String projectId,
  required String memberKey,
  required String grid,
}) => ['project', 'promote', projectId, memberKey, ..._grid(grid)];

/// `grid project import <path> <id>` — the only way a project gets a trunk.
/// [branch] is a *local* ref in the repository being imported; `HEAD` is the
/// CLI's own default and means whatever is checked out.
List<String> projectImportArgs({
  required String path,
  required String projectId,
  required String grid,
  String branch = 'HEAD',
}) => [
  'project',
  'import',
  path,
  projectId,
  '--branch',
  branch,
  ..._grid(grid),
];

/// `grid project clone <id> <dir>` — a real working clone on this member's own
/// branch, wired to ask `grid credential` for a token each time.
List<String> projectCloneArgs({
  required String projectId,
  required String directory,
  required String grid,
}) => ['project', 'clone', projectId, directory, ..._grid(grid)];

/// Where a clone of [projectName] goes when the user picked [parent] as the
/// place to put it: a folder of its own, named after the project.
///
/// `grid project clone` takes **the clone's own directory**, and refuses one
/// that already holds files it didn't put there — the guard that stops a
/// `checkout -B` resetting somebody's repository. The folder picker asks where
/// to *put* the copy, so handing its answer straight through pointed the clone
/// at a working directory full of other things: picking `~/WorkPlace/Grid` gave
/// "it already has files in it and was not created by `grid project clone`",
/// naming a folder the user never meant as the destination.
///
/// A parent already named after the project is taken as the clone's own folder
/// rather than nested inside itself, so re-cloning to refresh a copy is a matter
/// of picking it again.
///
/// Pure so `test/code/` can pin it: this decides where files land on someone's
/// computer, which is not a thing to find out by running it.
String cloneDestination({
  required String parent,
  required String projectName,
  required String projectId,
}) {
  final folder = cloneFolderName(
    projectName: projectName,
    projectId: projectId,
  );
  final trimmed = parent.replaceFirst(RegExp(r'[/\\]+$'), '');
  final base = trimmed.split(RegExp(r'[/\\]')).last;
  if (base == folder) return trimmed;
  return '$trimmed${Platform.pathSeparator}$folder';
}

/// The folder name a clone of this project takes.
///
/// The project's own name, with everything a path can't carry replaced — a name
/// is free text on the grid and may hold a slash, which would silently clone
/// somewhere other than where the user chose. A name with nothing usable left
/// falls back to the id, so the folder is always something the user can find.
String cloneFolderName({
  required String projectName,
  required String projectId,
}) {
  final safe = projectName
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '-')
      // Trailing dots and spaces are legal here and not on Windows; a copy
      // taken on a Mac and synced across shouldn't arrive unopenable.
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  if (safe.isNotEmpty) return safe;
  final id = projectId.trim();
  return id.isEmpty ? 'project' : 'project-${id.split('-').first}';
}

/// `grid project commit <id> -m <msg>` — land files without running an agent.
///
/// [files] are `LOCAL[:DEST]` specs, [deletes] are paths already in the branch.
/// The CLI refuses a call carrying neither, and so does the caller here — the
/// message can name the buttons rather than the wire fields.
List<String> projectCommitArgs({
  required String projectId,
  required String message,
  required String grid,
  List<String> files = const [],
  List<String> deletes = const [],
}) => [
  'project',
  'commit',
  projectId,
  '-m',
  message,
  for (final file in files) ...['--file', file],
  for (final path in deletes) ...['--delete', path],
  ..._grid(grid),
];

/// `grid project member list <id>` — who is in it, and the member key each one
/// is promoted and removed by.
List<String> memberListArgs({
  required String projectId,
  required String grid,
}) => ['project', 'member', 'list', projectId, ..._grid(grid)];

/// `grid project member add <id> --email <addr>`. The address is a *flag* here
/// and a positional on `grid members add`, which is the pair the CLI's own
/// guide warns is easy to confuse.
List<String> memberAddArgs({
  required String projectId,
  required String email,
  required String grid,
}) => ['project', 'member', 'add', projectId, '--email', email, ..._grid(grid)];

/// `grid project member remove <id> <member_key>` — by key, never by email:
/// `grid:<network>:<sub>` is not a path segment.
List<String> memberRemoveArgs({
  required String projectId,
  required String memberKey,
  required String grid,
}) => ['project', 'member', 'remove', projectId, memberKey, ..._grid(grid)];

/// `grid task list --project <id>` — [all] widens it from this member's own
/// runs to the whole team's, which is the point on a shared project.
List<String> taskListArgs({
  required String projectId,
  required String grid,
  bool all = false,
  List<String> states = const [],
  int? limit,
  String? after,
}) => [
  'task',
  'list',
  '--project',
  projectId,
  if (all) '--all',
  for (final state in states) ...['--state', state],
  if (limit != null) ...['--limit', '$limit'],
  if (after != null && after.isNotEmpty) ...['--after', after],
  ..._grid(grid),
];

/// `grid task create --project <id> --prompt <text>`.
///
/// [files] are `LOCAL[:DEST]` specs, committed before any provider can claim
/// the task — so the agent always finds them.
List<String> taskCreateArgs({
  required String projectId,
  required String prompt,
  required String grid,
  List<String> files = const [],
}) => [
  'task',
  'create',
  '--project',
  projectId,
  '--prompt',
  prompt,
  for (final file in files) ...['--file', file],
  ..._grid(grid),
];

/// `grid task follow <id>` — one JSON event per line until a terminal one.
///
/// [afterSeq] is the cursor: every event carries its `seq`, so a stream that
/// dies is resumed with the last one seen and the relay replays exactly what
/// follows. `-1` is the CLI's own default and means "from the start".
List<String> taskFollowArgs({
  required String taskId,
  required String grid,
  int afterSeq = -1,
}) => ['task', 'follow', taskId, '--after-seq', '$afterSeq', ..._grid(grid)];

/// `grid task fetch <id> --into <dir>` — the result on disk. Refused unless the
/// task has stopped, because until then the branch still holds only the input.
List<String> taskFetchArgs({
  required String taskId,
  required String into,
  required String grid,
}) => ['task', 'fetch', taskId, '--into', into, ..._grid(grid)];

/// `grid task cancel <id>` — frees the slot at once; the agent stops within
/// about half a minute. Nothing is rewound, so the branch stays fetchable.
List<String> taskCancelArgs({required String taskId, required String grid}) => [
  'task',
  'cancel',
  taskId,
  ..._grid(grid),
];

/// A `--file LOCAL[:DEST]` spec.
///
/// The CLI splits on the **last** colon, so a destination is appended rather
/// than substituted, and a local path that itself contains a colon still
/// resolves — passing one with no destination would not.
String fileSpec(String localPath, {String? destination}) =>
    (destination == null || destination.isEmpty)
    ? localPath
    : '$localPath:$destination';
