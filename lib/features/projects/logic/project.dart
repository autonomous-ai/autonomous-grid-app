import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// A folder on this computer the assistant is allowed to read.
///
/// Chats belong to a project: open one inside "my notes" and the assistant can
/// see those files while it answers, without anything being pasted into the
/// message. It's the folder the agent runs in (its working directory), nothing
/// more — it doesn't copy or upload anything.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.path,
    this.instructions = '',
    this.memory = const [],
    this.pinned = false,
  });

  final String id;

  /// The folder's own name, which is what the user recognises it by.
  final String name;
  final String path;

  /// Kept at the top of the list. A folder you come back to every day shouldn't
  /// sink under ones you opened once — pinning holds it in reach.
  final bool pinned;

  /// Standing house rules the assistant follows in this project's chats — the
  /// app's equivalent of a repo's `AGENTS.md`. Prepended to the agent's first
  /// turn so every chat opened here starts with the same guidance ("write in
  /// Vietnamese", "this is a Flutter app, use Dart idioms"). Empty means none.
  final String instructions;

  /// Facts the user asked the assistant to remember about this project, one per
  /// entry ("the prod DB is read-only", "ship notes to #eng"). Like
  /// [instructions] these ride along on the agent's first turn (see
  /// [projectStandingBrief]) — rules say *how* to work, memory says *what's
  /// true here*. Empty means nothing is remembered yet.
  final List<String> memory;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    if (instructions.isNotEmpty) 'instructions': instructions,
    if (memory.isNotEmpty) 'memory': memory,
    if (pinned) 'pinned': true,
  };

  static Project? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final path = json['path'];
    if (id is! String || id.isEmpty) return null;
    if (path is! String || path.isEmpty) return null;
    final name = json['name'];
    final instructions = json['instructions'];
    final memory = json['memory'];
    return Project(
      id: id,
      name: name is String && name.isNotEmpty ? name : folderName(path),
      path: path,
      instructions: instructions is String ? instructions : '',
      memory: memory is List
          ? [
              for (final entry in memory)
                if (entry is String && entry.trim().isNotEmpty) entry.trim(),
            ]
          : const [],
      pinned: json['pinned'] == true,
    );
  }

  /// A copy with [name], [instructions], [memory] or [pinned] changed; id and
  /// path are the project's identity and never move.
  Project copyWith({
    String? name,
    String? instructions,
    List<String>? memory,
    bool? pinned,
  }) => Project(
    id: id,
    name: name ?? this.name,
    path: path,
    instructions: instructions ?? this.instructions,
    memory: memory ?? this.memory,
    pinned: pinned ?? this.pinned,
  );
}

/// The last segment of a path — what a person calls the folder.
String folderName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// The standing guidance the assistant reads at the start of every chat in a
/// project: its house rules ([Project.instructions]) followed by the facts it's
/// been asked to remember ([Project.memory]). Returns '' when the project sets
/// neither, so a plain chat carries no preamble.
///
/// Pure so it can be unit-tested and shared by both agent senders (via
/// `withProjectInstructions`) — memory that never reaches the agent would be a
/// lie the card tells.
String projectStandingBrief(Project project) {
  final rules = project.instructions.trim();
  final memory = [
    for (final entry in project.memory)
      if (entry.trim().isNotEmpty) '- ${entry.trim()}',
  ];
  if (rules.isEmpty && memory.isEmpty) return '';

  final buffer = StringBuffer();
  if (rules.isNotEmpty) buffer.write(rules);
  if (memory.isNotEmpty) {
    if (rules.isNotEmpty) buffer.write('\n\n');
    buffer
      ..write('Remember about this project:\n')
      ..write(memory.join('\n'));
  }
  return buffer.toString();
}

/// Persists the projects as `~/.grid/app/projects.json`. App-owned (the CLI never
/// touches it) and lenient like the other app stores: a missing or corrupt file
/// reads as no projects rather than throwing.
class ProjectsStore {
  ProjectsStore({File? file}) : _file = file ?? GridPaths.projectsFile;

  final File _file;

  List<Project> load() {
    try {
      if (!_file.existsSync()) return const [];
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return const [];
      return [
        for (final raw in decoded)
          if (raw is Map<String, dynamic>) ?Project.fromJson(raw),
      ];
    } on Object {
      return const [];
    }
  }

  void save(List<Project> projects) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final p in projects) p.toJson()]),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final projectsStoreProvider = Provider<ProjectsStore>((ref) => ProjectsStore());

/// The projects, newest last. Loaded once on start; every change persists.
final projectsProvider = NotifierProvider<ProjectsController, List<Project>>(
  ProjectsController.new,
);

class ProjectsController extends Notifier<List<Project>> {
  @override
  List<Project> build() => ref.read(projectsStoreProvider).load();

  /// Create a project for the folder at [path], carrying the [name] the user
  /// gave it and any standing [instructions] they wrote up front.
  ///
  /// A blank [name] falls back to the folder's own name. A folder that's already
  /// a project is returned as it stands rather than added twice — this creates,
  /// it doesn't overwrite, so re-adding a folder never clobbers rules already on
  /// it.
  Project create({
    required String path,
    String name = '',
    String instructions = '',
  }) {
    final existing = state.where((p) => p.path == path).firstOrNull;
    if (existing != null) return existing;

    final project = Project(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? folderName(path) : name.trim(),
      path: path,
      instructions: instructions.trim(),
    );
    _commit([...state, project]);
    return project;
  }

  /// Add the folder at [path] with the folder's own name and no rules — the bare
  /// form of [create], kept for callers that just want a folder in the list.
  Project add(String path) => create(path: path);

  /// Set the standing rules the assistant follows in [id]'s chats. Trimmed;
  /// passing blank clears them. A project that isn't there any more is a no-op.
  void setInstructions(String id, String instructions) {
    final trimmed = instructions.trim();
    _commit([
      for (final project in state)
        if (project.id == id)
          project.copyWith(instructions: trimmed)
        else
          project,
    ]);
  }

  /// Remember [note] about [id] — appended to the project's [Project.memory] so
  /// the assistant carries it into every chat here. Trimmed; a blank note or a
  /// project that isn't there any more is a no-op. Duplicates are dropped so the
  /// same fact isn't remembered twice.
  void addMemory(String id, String note) {
    final trimmed = note.trim();
    if (trimmed.isEmpty) return;
    _commit([
      for (final project in state)
        if (project.id == id && !project.memory.contains(trimmed))
          project.copyWith(memory: [...project.memory, trimmed])
        else
          project,
    ]);
  }

  /// Forget the memory at [index] for [id]. An out-of-range index or a project
  /// that isn't there any more is a no-op.
  void removeMemoryAt(String id, int index) => _commit([
    for (final project in state)
      if (project.id == id && index >= 0 && index < project.memory.length)
        project.copyWith(memory: [...project.memory]..removeAt(index))
      else
        project,
  ]);

  /// Rename a project. The folder on disk is untouched — only the label the user
  /// sees changes. A blank name is ignored (a nameless row can't be told apart),
  /// as is a project that isn't there any more.
  void rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _commit([
      for (final project in state)
        if (project.id == id) project.copyWith(name: trimmed) else project,
    ]);
  }

  /// Pin or unpin a project, which floats it to the top of the list (see
  /// [sortedProjectsProvider]). A project that isn't there any more is a no-op.
  void setPinned(String id, bool pinned) => _commit([
    for (final project in state)
      if (project.id == id) project.copyWith(pinned: pinned) else project,
  ]);

  /// Forget a project. The folder on disk is left alone — this is the app's
  /// list, not the user's files.
  void remove(String id) => _commit([
    for (final project in state)
      if (project.id != id) project,
  ]);

  void _commit(List<Project> next) {
    state = List.unmodifiable(next);
    ref.read(projectsStoreProvider).save(next);
  }
}

/// One project by id, or null when it was removed (a chat can outlive it).
final projectByIdProvider = Provider.family<Project?, String?>((ref, id) {
  if (id == null) return null;
  return ref.watch(projectsProvider).where((p) => p.id == id).firstOrNull;
});

/// Projects in display order: pinned ones first, each group keeping the stored
/// (newest-last) order. What the rail and the manage screen render, so pinning
/// visibly floats a project to the top everywhere at once.
final sortedProjectsProvider = Provider<List<Project>>((ref) {
  final projects = ref.watch(projectsProvider);
  return [
    for (final p in projects)
      if (p.pinned) p,
    for (final p in projects)
      if (!p.pinned) p,
  ];
});
