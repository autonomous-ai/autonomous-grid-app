/// A Codex `fileChange` item: the rows the feed shows, and the record the
/// open/undo bar keeps.
///
/// It used to be only the record, so a patch Codex applied never appeared in
/// the steps: a turn that rewrote three files read as a turn that ran some
/// commands. Codex's own VS Code panel draws the change itself — a unified
/// diff per file (`ly()` and `oy()` in its webview) — and so does this: a row
/// per file, titled the way a Claude edit is ("Edit · a.dart"), with the diff
/// behind the fold, coloured as one.
///
/// **`kind` is an object** — `{type: add | delete | update, move_path?}` — in
/// the app-server's own schema for the pinned build, and the extension reads
/// `kind.type`. The old `exec --json` transport sent a bare string and the
/// parser went on reading one, so every change fell through to `update` and a
/// file Codex created was never offered to open or undo. Both shapes are read.
///
/// What `diff` holds depends on the kind, and the extension reads it the same
/// way: a unified diff for an update, the new file's contents for an add.
///
/// TODO(BE): an update's diff is shown but not kept, so an *edited* file still
/// can't be undone — only a created one ([codexAddedPaths]). Keeping it means
/// carrying it through [CodexFileChange] into the changes bar.
library;

import '../../core/folder_name.dart';
import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_items.dart' show codexItemStatus;

/// One file in a patch: where it is, what happened to it, where it went (a
/// rename), and the change text.
typedef CodexPatchFile = ({
  String path,
  CodexFileChangeKind kind,
  String? movedTo,
  String diff,
});

/// What one `fileChange` item stands for: a row per file, and — once the
/// patch has landed — the files it touched, for the open/undo bar. An
/// in-flight patch has written nothing to open, and a declined one nothing at
/// all, so the record waits for `completed`.
List<CodexEvent> codexFileChangeEvents(
  String id,
  Map<String, dynamic> item, {
  String? parent,
}) {
  final files = codexPatchFiles(item['changes']);
  final status = codexItemStatus(item['status']);
  return [
    for (final (index, file) in files.indexed)
      CodexActivityEvent(
        _row(files.length == 1 ? id : '$id:$index', file, status, parent),
      ),
    if (status == AgentActivityStatus.done && files.isNotEmpty)
      CodexFileChangeEvent([
        for (final file in files)
          (path: file.movedTo ?? file.path, kind: file.kind),
      ]),
  ];
}

/// The files of a `fileChange` item, read leniently: an entry without a path
/// is skipped rather than fatal.
List<CodexPatchFile> codexPatchFiles(Object? raw) => [
  if (raw is List)
    for (final entry in raw)
      if (entry is Map && '${entry['path'] ?? ''}'.trim().isNotEmpty)
        (
          path: '${entry['path']}'.trim(),
          kind: codexChangeKind(entry['kind']),
          movedTo: _movedTo(entry['kind']),
          diff: '${entry['diff'] ?? ''}',
        ),
];

/// `add` / `update` / `delete`, from the app-server's `{type: …}` or the old
/// bare string. Anything else reads as an update — the conservative choice,
/// since only an add is recorded for undo, so mislabelling one drops it rather
/// than faking an undo.
CodexFileChangeKind codexChangeKind(Object? raw) => switch (raw) {
  'add' || {'type': 'add'} => CodexFileChangeKind.add,
  'delete' || {'type': 'delete'} => CodexFileChangeKind.delete,
  _ => CodexFileChangeKind.update,
};

String? _movedTo(Object? kind) {
  final moved = kind is Map ? kind['move_path'] : null;
  return moved is String && moved.trim().isNotEmpty ? moved.trim() : null;
}

AgentActivity _row(
  String id,
  CodexPatchFile file,
  AgentActivityStatus status,
  String? parent,
) {
  final (tool, request) = switch (file.kind) {
    CodexFileChangeKind.add => ('Write', file.diff),
    CodexFileChangeKind.update => ('Edit', _unifiedDiff(file)),
    CodexFileChangeKind.delete => ('Delete', null),
  };
  final moved = file.movedTo;
  final name = folderName(file.path);
  return AgentActivity(
    id: id,
    kind: AgentActivityKind.tool,
    label: moved == null
        ? '$tool · $name'
        : '$tool · $name → ${folderName(moved)}',
    status: status,
    tool: tool,
    request: clipToolPayload(request),
    parent: parent,
  );
}

/// An update's diff with the file named on top, the way a unified diff opens
/// — which is also what tells the feed to colour it as one. Left alone when
/// Codex already sent the headers.
String _unifiedDiff(CodexPatchFile file) {
  final body = file.diff.trimLeft();
  if (body.startsWith('--- ') || body.startsWith('diff --git ')) return body;
  return '--- ${file.path}\n+++ ${file.movedTo ?? file.path}\n$body';
}
