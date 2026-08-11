/// The rules for folding a downloaded backup into what this machine already
/// has.
///
/// Nothing is thrown away without the user seeing it first:
///
/// * A chat this machine has and the backup doesn't is **left alone**. Someone
///   who restores before they have ever backed up must not lose the history
///   they only have here. The cost, stated plainly because it surprises people:
///   **deleting a chat on one machine does not delete it on the other.**
///   Tombstones would fix that and are not in this version.
/// * A chat on **both** sides is decided by [cloudCopyWins] — the newer copy
///   stays. Before any of it is written the user is shown which chats that
///   would overwrite ([previewRestore]) and can stop; whatever is replaced is
///   still recoverable from the rollback zip the workspace writes first.
///
/// Everything here works on generic maps rather than parsed models, and that is
/// deliberate: the two machines may run different builds, and decoding a chat
/// into this build's model and re-encoding it would quietly drop any field this
/// build doesn't know about yet.
library;

import 'sync_bundle.dart';

/// What happened to one chat.
enum ChatMergeAction {
  /// Only the backup had it.
  addedFromCloud,

  /// Both had it and the backup's copy was the newer one, so it was written
  /// over this machine's.
  replacedByCloud,

  /// Both had it and this machine's copy is the newer one — left as it is.
  keptLocal,
}

/// The chats to write, and the story to tell about the merge.
typedef ChatMergeResult = ({
  Map<String, Map<String, Object?>> write,
  Map<String, ChatMergeAction> actions,
});

/// Folds [cloud] into [local], both keyed by chat id.
///
/// Only the entries in the returned `write` map need saving; a chat that only
/// exists locally never appears there, which is what keeps it safe.
///
/// [mediaRewrites] maps a path as the *other* machine wrote it to where the
/// same file now lives here — applied to chats coming from the snapshot, so
/// their images resolve instead of pointing into a stranger's home folder.
ChatMergeResult mergeChatFiles({
  required Map<String, Map<String, Object?>> local,
  required Map<String, Map<String, Object?>> cloud,
  Map<String, String> mediaRewrites = const {},
}) {
  final write = <String, Map<String, Object?>>{};
  final actions = <String, ChatMergeAction>{};
  for (final entry in cloud.entries) {
    final id = entry.key;
    final mine = local[id];
    if (mine == null) {
      write[id] = rewriteMediaPaths(entry.value, mediaRewrites);
      actions[id] = ChatMergeAction.addedFromCloud;
      continue;
    }
    if (cloudCopyWins(mine: mine, theirs: entry.value)) {
      write[id] = rewriteMediaPaths(entry.value, mediaRewrites);
      actions[id] = ChatMergeAction.replacedByCloud;
      continue;
    }
    actions[id] = ChatMergeAction.keptLocal;
  }
  return (write: write, actions: actions);
}

/// Which copy of a chat both machines have is the one to keep.
///
/// Newest `updatedAt` wins — the stamp the app writes *inside* the file when a
/// message lands, never the file's own modification time, which a copy, an
/// unzip or the restore itself would reset to now.
///
/// A tie goes to whichever copy has more messages, and that matters more than
/// it looks: two machines can genuinely write the same second, and chats saved
/// before stamps carried a zone read as the epoch on both sides. In both cases
/// "newest" cannot decide, and the longer transcript is the one that loses
/// nothing.
///
/// Shared with [previewRestore] on purpose — the dialog must predict exactly
/// what the merge will do, and two copies of this rule would drift.
bool cloudCopyWins({
  required Map<String, Object?> mine,
  required Map<String, Object?> theirs,
}) {
  final ours = parseSyncTimestamp(mine['updatedAt']);
  final other = parseSyncTimestamp(theirs['updatedAt']);
  if (other.isAfter(ours)) return true;
  if (ours.isAfter(other)) return false;
  return _messageCount(theirs) > _messageCount(mine);
}

int _messageCount(Map<String, Object?> chat) {
  final messages = chat['messages'];
  return messages is List ? messages.length : 0;
}

/// What a restore would do, worked out before anything is written.
///
/// [replacedTitles] is what the confirmation dialog shows: writing over a chat
/// that is already here is the one lossy thing a restore does, so it has to be
/// named — a count alone doesn't let anyone judge it. [keptLocal] is the
/// reassuring half: chats where this computer's copy is the newer one and stays.
typedef SyncRestorePreview = ({
  int added,
  int replaced,
  int keptLocal,
  List<String> replacedTitles,
});

/// Works out [SyncRestorePreview] for a backup that has been opened but not yet
/// applied, using the same rule the merge will.
SyncRestorePreview previewRestore({
  required Map<String, Map<String, Object?>> local,
  required Map<String, Map<String, Object?>> cloud,
}) {
  final titles = <String>[];
  var added = 0;
  var kept = 0;
  for (final entry in cloud.entries) {
    final mine = local[entry.key];
    if (mine == null) {
      added++;
      continue;
    }
    if (!cloudCopyWins(mine: mine, theirs: entry.value)) {
      kept++;
      continue;
    }
    final title = mine['title'];
    titles.add(title is String && title.isNotEmpty ? title : 'Untitled chat');
  }
  return (
    added: added,
    replaced: titles.length,
    keptLocal: kept,
    replacedTitles: titles,
  );
}

/// Reads a stamp written by any build of the app.
///
/// Since the UTC change these carry a `Z`; older files don't, and are read as
/// this machine's local time — which is what they were when they were written.
/// Anything unreadable sorts oldest so it can only ever lose a comparison, not
/// win one on a technicality.
DateTime parseSyncTimestamp(Object? raw) {
  if (raw is! String) return _epoch;
  return DateTime.tryParse(raw)?.toLocal() ?? _epoch;
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// A copy of [chat] with every media and file path in [rewrites] replaced.
///
/// Untouched paths — an attachment that didn't travel — are left exactly as
/// they were rather than dropped: the chat then shows a file it can't find,
/// which is the truth, and the manifest says why.
Map<String, Object?> rewriteMediaPaths(
  Map<String, Object?> chat,
  Map<String, String> rewrites,
) {
  if (rewrites.isEmpty) return chat;
  final messages = chat['messages'];
  if (messages is! List) return chat;
  return {
    ...chat,
    'messages': [
      for (final message in messages)
        if (message is Map<String, Object?>)
          _rewriteMessage(message, rewrites)
        else
          message,
    ],
  };
}

Map<String, Object?> _rewriteMessage(
  Map<String, Object?> message,
  Map<String, String> rewrites,
) => {
  ...message,
  if (message['media'] is List)
    'media': _rewriteList(message['media'] as List, rewrites),
  if (message['files'] is List)
    'files': _rewriteList(message['files'] as List, rewrites),
};

List<Object?> _rewriteList(List<Object?> items, Map<String, String> rewrites) {
  return [
    for (final item in items)
      if (item is Map<String, Object?> && rewrites[item['path']] != null)
        {...item, 'path': rewrites[item['path']]}
      else
        item,
  ];
}

/// Where each media file in [manifest] now lives on this machine, keyed by the
/// path the snapshot's author wrote — the shape [mergeChatFiles] wants.
Map<String, String> buildMediaRewrites({
  required SyncManifest manifest,
  required String Function(SyncMediaEntry entry) localPathFor,
}) => {for (final entry in manifest.media) entry.source: localPathFor(entry)};

/// Merges two lists of `{"id": …}` records — the shape of `prompts.json` and
/// `projects.json`.
///
/// Local wins a collision unless [preferNewer] finds a newer `updatedAt` on the
/// incoming copy. Records the local list doesn't have are appended in the order
/// the snapshot had them, so a machine that has never synced ends up with the
/// other one's list intact rather than interleaved.
List<Map<String, Object?>> mergeRecordsById({
  required List<Map<String, Object?>> local,
  required List<Map<String, Object?>> cloud,
  bool preferNewer = false,
}) {
  final out = <Map<String, Object?>>[];
  final byId = <String, int>{};
  for (final record in local) {
    final id = record['id'];
    if (id is String) byId[id] = out.length;
    out.add(record);
  }
  for (final record in cloud) {
    final id = record['id'];
    final at = id is String ? byId[id] : null;
    if (at == null) {
      out.add(record);
      continue;
    }
    if (!preferNewer) continue;
    final mine = parseSyncTimestamp(out[at]['updatedAt']);
    if (parseSyncTimestamp(record['updatedAt']).isAfter(mine)) out[at] = record;
  }
  return out;
}
