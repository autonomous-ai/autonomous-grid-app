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
  });

  final String id;

  /// The folder's own name, which is what the user recognises it by.
  final String name;
  final String path;

  /// Standing house rules the assistant follows in this project's chats — the
  /// app's equivalent of a repo's `AGENTS.md`. Prepended to the agent's first
  /// turn so every chat opened here starts with the same guidance ("write in
  /// Vietnamese", "this is a Flutter app, use Dart idioms"). Empty means none.
  final String instructions;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    if (instructions.isNotEmpty) 'instructions': instructions,
  };

  static Project? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final path = json['path'];
    if (id is! String || id.isEmpty) return null;
    if (path is! String || path.isEmpty) return null;
    final name = json['name'];
    final instructions = json['instructions'];
    return Project(
      id: id,
      name: name is String && name.isNotEmpty ? name : folderName(path),
      path: path,
      instructions: instructions is String ? instructions : '',
    );
  }

  /// A copy with [name] or [instructions] changed; id and path are the project's
  /// identity and never move.
  Project copyWith({String? name, String? instructions}) => Project(
    id: id,
    name: name ?? this.name,
    path: path,
    instructions: instructions ?? this.instructions,
  );

  /// Whether the folder is still there. A project whose folder was moved or
  /// deleted stays in the list but is shown as missing — silently dropping it
  /// would lose the chats that belong to it.
  bool get exists => Directory(path).existsSync();
}

/// The last segment of a path — what a person calls the folder.
String folderName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
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

  /// Add the folder at [path]. A folder that's already a project is returned as
  /// it stands rather than added twice.
  Project add(String path) {
    final existing = state.where((p) => p.path == path).firstOrNull;
    if (existing != null) return existing;

    final project = Project(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: folderName(path),
      path: path,
    );
    _commit([...state, project]);
    return project;
  }

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
