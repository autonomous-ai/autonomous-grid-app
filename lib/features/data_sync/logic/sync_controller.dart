import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/app_info.dart';
import '../../auth/logic/session_controller.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';
import '../../prompts/logic/prompt_library_controller.dart';
import 'sync_bundle.dart';
import 'sync_client.dart';
import 'sync_envelope.dart';
import 'sync_keyring.dart';
import 'sync_merge.dart';
import 'sync_state.dart';
import 'sync_workspace.dart';

/// The disk side of Sync & Backup. Overridden in tests with a temp directory.
final syncWorkspaceProvider = Provider<SyncWorkspace>((ref) => SyncWorkspace());

/// The control-plane client, or null when nobody is signed in — the screen shows
/// a sign-in prompt rather than buttons that would fail.
final syncClientProvider = Provider<SyncClient?>((ref) {
  final token = ref.watch(sessionProvider).sessionToken;
  if (token == null || token.isEmpty) return null;
  return SyncClient(apiUrl: ref.watch(gridApiUrlProvider), sessionToken: token);
});

/// The backups on the server, newest first.
///
/// Invalidated after every upload or delete, so the list is never the reason a
/// user thinks a backup exists that doesn't.
final syncVersionsProvider = FutureProvider<List<SyncVersion>>((ref) async {
  final client = ref.watch(syncClientProvider);
  if (client == null) return const [];
  final (versions, error) = await client.listVersions();
  if (error != null) throw error;
  return versions ?? const [];
});

/// Drives one upload or download at a time.
final syncControllerProvider = NotifierProvider<SyncController, SyncRunState>(
  SyncController.new,
);

class SyncController extends Notifier<SyncRunState> {
  @override
  SyncRunState build() => const SyncIdle();

  /// Packs this machine's chats into a new backup sealed with [password].
  ///
  /// Each upload is a new version with its own key, so this can never overwrite
  /// what another machine put there — and the password is only ever this
  /// backup's password.
  Future<void> upload({required String password, String? hint}) async {
    final client = ref.read(syncClientProvider);
    if (client == null) {
      state = const SyncFailed('Sign in to back up your chats.');
      return;
    }
    if (_chatIsRunning) {
      state = const SyncFailed(
        'A chat is still generating. Wait for it to finish, then try again.',
      );
      return;
    }
    final log = ref.read(appLogProvider);
    try {
      await _upload(client, password: password, hint: hint, log: log);
    } on SyncApiError catch (error) {
      log.failure('sync', 'upload failed: ${error.debugDetail}');
      state = SyncFailed(error.message);
    } on Object catch (error, stack) {
      log.failure('sync', 'upload failed', error: error, stackTrace: stack);
      state = const SyncFailed("Couldn't finish the backup. Nothing was sent.");
    }
  }

  Future<void> _upload(
    SyncClient client, {
    required String password,
    required String? hint,
    required AppLog log,
  }) async {
    state = const SyncBusy(SyncStage.gathering);
    final workspace = ref.read(syncWorkspaceProvider);
    final chats = await workspace.readChats();
    final prompts = await workspace.readPrompts();
    final projects = await workspace.readProjects();

    final candidates = await workspace.statMedia(
      referencedMediaPaths(chats.values),
    );
    final plan = planSyncMedia(
      candidates: candidates,
      outputsPath: workspace.outputsDir.path,
    );

    state = const SyncBusy(SyncStage.sealing);
    final sealed = <SyncMediaEntry>[];
    final envelopes = <String, List<int>>{};
    final skipped = [...plan.skipped];
    for (final pick in plan.picked) {
      final bytes = await workspace.readMedia(pick.source);
      if (bytes == null) {
        // It was there when we planned and isn't now. Recording it keeps the
        // other machine able to explain the gap instead of showing a broken
        // image with no reason.
        skipped.add(
          SyncSkippedMedia(source: pick.source, reason: SyncSkipReason.missing),
        );
        continue;
      }
      final media = await sealSyncMedia(bytes);
      envelopes[media.oid] = media.envelope;
      sealed.add(
        SyncMediaEntry(
          oid: media.oid,
          key: media.key,
          source: pick.source,
          rel: pick.rel,
          bytes: pick.bytes,
        ),
      );
    }

    final (remote, checkError) = await client.checkObjects([
      for (final entry in sealed) entry.oid,
    ]);
    if (checkError != null) throw checkError;
    final missing = remote!.upload.keys.toList();
    for (var i = 0; i < missing.length; i++) {
      state = SyncBusy(
        SyncStage.uploadingMedia,
        done: i,
        total: missing.length,
      );
      final error = await client.putObject(
        remote.upload[missing[i]]!,
        envelopes[missing[i]]!,
      );
      if (error != null) throw error;
    }
    // The server checks what actually landed. Anything it wouldn't take is
    // dropped from this backup rather than referenced by it: a manifest naming
    // a file that isn't there is a restore that fails halfway through.
    final (unstored, commitError) = await client.commitObjects(missing);
    if (commitError != null) throw commitError;
    if (unstored!.isNotEmpty) {
      final lost = unstored.toSet();
      for (final entry in sealed.where((e) => lost.contains(e.oid))) {
        skipped.add(
          SyncSkippedMedia(
            source: entry.source,
            reason: SyncSkipReason.missing,
          ),
        );
      }
      sealed.removeWhere((entry) => lost.contains(entry.oid));
    }

    state = const SyncBusy(SyncStage.uploadingSnapshot);
    final manifest = SyncManifest(
      createdAt: DateTime.now().toUtc(),
      device: _deviceLabel,
      app: await _appVersion(),
      chatCount: chats.length,
      promptCount: prompts.length,
      projectCount: projects.length,
      media: sealed,
      skipped: skipped,
    );
    final key = SyncVersionKey.generate();
    final blob = await key.wrap(password: password, hint: hint);
    final envelope = await sealSyncEnvelope(
      plaintext: packSyncArchive({
        syncManifestEntry: _json(manifest.toJson()),
        for (final entry in chats.entries)
          '$syncChatsPrefix${entry.key}.json': _json(entry.value),
        if (prompts.isNotEmpty) syncPromptsEntry: _json(prompts),
        if (projects.isNotEmpty) syncProjectsEntry: _json(projects),
      }),
      key: key.secretKey,
      header: SyncEnvelopeHeader(
        kind: syncEnvelopeKindSnapshot,
        createdAt: manifest.createdAt,
        device: manifest.device,
        app: manifest.app,
        key: blob.toJson(),
        counts: {
          'chats': chats.length,
          'prompts': prompts.length,
          'projects': projects.length,
          'media': sealed.length,
        },
        objectIds: manifest.objectIds,
      ),
    );

    final (version, error) = await client.putSnapshot(envelope);
    if (error != null) throw error;
    if (version != null) {
      await workspace.writeMarker(version, DateTime.now());
    }
    ref.invalidate(syncVersionsProvider);
    log.info('sync', 'uploaded backup v$version (${envelope.length} bytes)');
    state = SyncSucceeded(
      _uploadSummary(chats.length, missing.length, skipped.length),
    );
  }

  /// Restores [version] into this machine.
  ///
  /// [confirm] is asked before anything is written, and only when the backup
  /// would overwrite chats this computer already has — the one lossy thing a
  /// restore does. Answering no stops with nothing changed.
  Future<void> download({
    required SyncVersion version,
    required String password,
    required Future<bool> Function(SyncRestorePreview) confirm,
  }) async {
    final client = ref.read(syncClientProvider);
    if (client == null) {
      state = const SyncFailed('Sign in to restore a backup.');
      return;
    }
    if (_chatIsRunning) {
      state = const SyncFailed(
        'A chat is still generating. Wait for it to finish, then try again.',
      );
      return;
    }
    final log = ref.read(appLogProvider);
    try {
      await _download(
        client,
        version: version,
        password: password,
        confirm: confirm,
        log: log,
      );
    } on SyncDecryptException {
      state = const SyncFailed(
        "That password doesn't open this backup. Nothing was changed.",
      );
    } on SyncFormatException catch (error) {
      log.failure('sync', 'restore failed: ${error.message}');
      state = const SyncFailed(
        "This backup is damaged and couldn't be opened. Nothing was changed.",
      );
    } on SyncApiError catch (error) {
      log.failure('sync', 'restore failed: ${error.debugDetail}');
      state = SyncFailed(error.message);
    } on Object catch (error, stack) {
      log.failure('sync', 'restore failed', error: error, stackTrace: stack);
      state = const SyncFailed("Couldn't restore this backup.");
    }
  }

  Future<void> _download(
    SyncClient client, {
    required SyncVersion version,
    required String password,
    required Future<bool> Function(SyncRestorePreview) confirm,
    required AppLog log,
  }) async {
    // The password check first, on 48 bytes: a wrong one costs a second here
    // instead of a download, and nothing on this machine has been touched yet.
    state = const SyncBusy(SyncStage.sealing);
    final key = await SyncVersionKey.unwrap(
      blob: version.keyBlob,
      password: password,
    );

    state = const SyncBusy(SyncStage.downloading);
    final (payload, error) = await client.getSnapshot(version.version);
    if (error != null) throw error;
    final entries = unpackSyncArchive(
      await openSyncEnvelope(envelope: payload!, key: key.secretKey),
    );
    final manifest = readSyncManifest(entries);

    final workspace = ref.read(syncWorkspaceProvider);
    final incoming = _chatsIn(entries);
    // Ask before anything is written, and before the media transfers — a user
    // who says no should not have paid for a download they cancelled.
    final preview = previewRestore(
      local: await workspace.readChats(),
      cloud: incoming,
    );
    if (preview.replaced > 0 && !await confirm(preview)) {
      state = const SyncIdle();
      return;
    }

    var mediaRestored = 0;
    for (var i = 0; i < manifest.media.length; i++) {
      final entry = manifest.media[i];
      state = SyncBusy(
        SyncStage.downloadingMedia,
        done: i,
        total: manifest.media.length,
      );
      if (File(workspace.localMediaPath(entry)).existsSync()) continue;
      final (object, objectError) = await client.getObject(entry.oid);
      if (objectError != null) {
        // One missing picture must not cost the user the whole restore — the
        // chat text is the thing they came for.
        log.warn(
          'sync',
          'media ${entry.oid} unavailable: ${objectError.message}',
        );
        continue;
      }
      await workspace.writeMedia(
        entry,
        await openSyncMedia(envelope: object!, key: entry.key),
      );
      mediaRestored++;
    }

    state = const SyncBusy(SyncStage.merging);
    await workspace.backup(_stampNow());
    final merged = mergeChatFiles(
      local: await workspace.readChats(),
      cloud: incoming,
      mediaRewrites: buildMediaRewrites(
        manifest: manifest,
        localPathFor: workspace.localMediaPath,
      ),
    );
    await workspace.applyChats(merged.write);
    await _mergeLists(workspace, entries);
    await workspace.writeMarker(version.version, DateTime.now());

    // The screens hold all three lists in memory, so writing the files is only
    // half of a restore — without this the chats are on disk and nowhere in the
    // app until the next launch, which is exactly what it looks like when a
    // restore has failed.
    //
    // Chats get a targeted re-read rather than a provider rebuild: rebuilding
    // tears down anything in flight and moves the user off whatever they had
    // open. Projects and prompts hold no such state, so a rebuild is the
    // simplest correct thing for them.
    await ref.read(chatSessionsProvider.notifier).reloadFromDisk();
    ref.invalidate(projectsProvider);
    ref.invalidate(promptLibraryProvider);
    log.info(
      'sync',
      'restored backup v${version.version}: ${merged.write.length} chats written',
    );
    state = SyncSucceeded(_restoreSummary(merged.actions, mediaRestored));
  }

  /// Removes one backup from the server. Deliberately no password — see the
  /// route's own note.
  Future<void> deleteVersion(int version) async {
    final client = ref.read(syncClientProvider);
    if (client == null) return;
    final error = await client.deleteVersion(version);
    if (error != null) {
      state = SyncFailed(error.message);
      return;
    }
    ref.invalidate(syncVersionsProvider);
    state = SyncSucceeded('Backup $version deleted.');
  }

  /// Removes every backup this account has.
  Future<void> deleteEverything() async {
    final client = ref.read(syncClientProvider);
    if (client == null) return;
    final error = await client.deleteEverything();
    if (error != null) {
      state = SyncFailed(error.message);
      return;
    }
    ref.invalidate(syncVersionsProvider);
    state = const SyncSucceeded('All cloud backups deleted.');
  }

  /// Clears a finished message so the screen goes back to its resting state.
  void acknowledge() => state = const SyncIdle();

  Future<void> _mergeLists(
    SyncWorkspace workspace,
    Map<String, Uint8List> entries,
  ) async {
    final prompts = _listIn(entries, syncPromptsEntry);
    if (prompts.isNotEmpty) {
      await workspace.writePrompts(
        mergeRecordsById(
          local: await workspace.readPrompts(),
          cloud: prompts,
          preferNewer: true,
        ),
      );
    }
    final projects = _listIn(entries, syncProjectsEntry);
    if (projects.isNotEmpty) {
      // Local wins a collision: a project's `path` is this machine's folder,
      // and the other machine's copy would point at a directory that isn't here.
      await workspace.writeProjects(
        mergeRecordsById(
          local: await workspace.readProjects(),
          cloud: projects,
        ),
      );
    }
  }

  bool get _chatIsRunning => ref.read(chatSessionsProvider).phases.isNotEmpty;

  /// What this machine calls itself, for the "from" column in the backup list.
  String get _deviceLabel {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? 'This computer' : name;
  }

  Future<String> _appVersion() async {
    try {
      return await ref.read(appVersionProvider.future);
    } on Object {
      // Only ever cosmetic — it labels the backup in a list. A platform channel
      // that didn't answer must not be why a backup fails.
      return '';
    }
  }
}

List<int> _json(Object? value) =>
    utf8.encode(const JsonEncoder.withIndent('  ').convert(value));

Map<String, Map<String, Object?>> _chatsIn(Map<String, Uint8List> entries) {
  final out = <String, Map<String, Object?>>{};
  for (final entry in entries.entries) {
    if (!entry.key.startsWith(syncChatsPrefix)) continue;
    final decoded = _decode(entry.value);
    if (decoded is! Map<String, Object?>) continue;
    final id = decoded['id'];
    if (id is String && id.isNotEmpty) out[id] = decoded;
  }
  return out;
}

List<Map<String, Object?>> _listIn(
  Map<String, Uint8List> entries,
  String name,
) {
  final decoded = _decode(entries[name]);
  return [
    if (decoded is List)
      for (final item in decoded)
        if (item is Map<String, Object?>) item,
  ];
}

Object? _decode(List<int>? bytes) {
  if (bytes == null) return null;
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
}

/// A filename-safe UTC stamp for the rollback copy.
String _stampNow() =>
    DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');

String _uploadSummary(int chats, int mediaSent, int skipped) {
  final parts = <String>[
    '$chats ${chats == 1 ? 'chat' : 'chats'} backed up',
    if (mediaSent > 0) '$mediaSent new ${mediaSent == 1 ? 'file' : 'files'}',
    if (skipped > 0)
      "$skipped ${skipped == 1 ? 'file' : 'files'} couldn't travel",
  ];
  return '${parts.join(' · ')}.';
}

String _restoreSummary(Map<String, ChatMergeAction> actions, int media) {
  var added = 0;
  var replaced = 0;
  for (final action in actions.values) {
    if (action == ChatMergeAction.addedFromCloud) added++;
    if (action == ChatMergeAction.replacedByCloud) replaced++;
  }
  if (added == 0 && replaced == 0) {
    return 'That backup held nothing to restore.';
  }
  final parts = <String>[
    if (added > 0) '$added new ${added == 1 ? 'chat' : 'chats'}',
    if (replaced > 0) '$replaced replaced',
    if (media > 0) '$media ${media == 1 ? 'file' : 'files'}',
  ];
  return '${parts.join(' · ')} restored. '
      'Chats only on this computer were left alone.';
}
