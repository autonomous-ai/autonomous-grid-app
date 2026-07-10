import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// The Chat tab's remembered selections — the grid, model, and agent backend the
/// user last used — so reopening the app restores them instead of resetting to
/// defaults.
///
/// [agent] is stored as a plain string (an `AgentBackend.name`) so this
/// app-owned store stays free of any feature enum; the feature layer maps it
/// back. All fields are optional: a field is null until the user first picks it.
class ChatPrefs {
  const ChatPrefs({this.networkId, this.model, this.agent});

  /// No remembered selection yet — the state before the first launch that saves.
  static const empty = ChatPrefs();

  final String? networkId;
  final String? model;
  final String? agent;

  ChatPrefs copyWith({String? networkId, String? model, String? agent}) =>
      ChatPrefs(
        networkId: networkId ?? this.networkId,
        model: model ?? this.model,
        agent: agent ?? this.agent,
      );

  factory ChatPrefs.fromJson(Map<String, dynamic> json) => ChatPrefs(
    networkId: json['networkId'] as String?,
    model: json['model'] as String?,
    agent: json['agent'] as String?,
  );

  Map<String, Object?> toJson() => {
    'networkId': networkId,
    'model': model,
    'agent': agent,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatPrefs &&
      other.networkId == networkId &&
      other.model == model &&
      other.agent == agent;

  @override
  int get hashCode => Object.hash(networkId, model, agent);
}

/// Persists [ChatPrefs] as `~/.grid/app/chat_prefs.json`. App-owned (the CLI
/// never touches it) and kept lenient like the other app stores: a missing or
/// corrupt file reads as [ChatPrefs.empty] rather than throwing.
///
/// The file is overridable so tests point at a temp path and never read or write
/// a real grid home.
class ChatPrefsStore {
  ChatPrefsStore({File? file}) : _file = file ?? GridPaths.chatPrefsFile;

  final File _file;

  /// The saved selections, or [ChatPrefs.empty] when nothing has been saved yet
  /// (or the file is unreadable).
  ChatPrefs load() {
    try {
      if (!_file.existsSync()) return ChatPrefs.empty;
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return ChatPrefs.empty;
      return ChatPrefs.fromJson(decoded);
    } on Object {
      return ChatPrefs.empty;
    }
  }

  /// Write [prefs] to disk, creating the `app/` directory on first use.
  void save(ChatPrefs prefs) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(prefs.toJson()),
      flush: true,
    );
  }
}

/// The prefs store, overridden in tests with a temp-file-backed instance.
final chatPrefsStoreProvider = Provider<ChatPrefsStore>(
  (ref) => ChatPrefsStore(),
);

/// The live remembered Chat selections. Loaded once on start; each setter
/// updates state and persists, so the selection survives an app restart.
///
/// Written from three places that own a different piece — the grid switcher
/// ([selectedNetworkProvider]), the model picker, and the agent picker
/// ([agentBackendProvider]) — but read back as one object.
final chatPrefsProvider = NotifierProvider<ChatPrefsController, ChatPrefs>(
  ChatPrefsController.new,
);

class ChatPrefsController extends Notifier<ChatPrefs> {
  @override
  ChatPrefs build() => ref.read(chatPrefsStoreProvider).load();

  void setNetwork(String networkId) =>
      _update(state.copyWith(networkId: networkId));

  void setModel(String model) => _update(state.copyWith(model: model));

  void setAgent(String agent) => _update(state.copyWith(agent: agent));

  void _update(ChatPrefs next) {
    if (next == state) return;
    state = next;
    ref.read(chatPrefsStoreProvider).save(next);
  }
}
