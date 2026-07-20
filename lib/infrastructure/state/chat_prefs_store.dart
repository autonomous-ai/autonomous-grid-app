import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../cli/agent_event.dart';

/// The chat's remembered selections — the grid and the model the user last used,
/// how much they let the agent do, and which theme they chose — so reopening the
/// app restores them instead of resetting to defaults. The grid and model are
/// null until first picked; [approval] and [themeMode] always have a value.
class ChatPrefs {
  const ChatPrefs({
    this.networkId,
    this.model,
    this.approval = AgentApprovalMode.ask,
    this.themeMode = ThemeMode.light,
    this.chatAgent = defaultChatAgent,
  });

  /// The agent that answers chats out of the box — `hermes`, mirroring the
  /// `kChatAgent` default in the agents catalog. Stored as a bare id string
  /// because this layer can't reach the `AgentTool` enum (infrastructure never
  /// depends on a feature); the agents feature maps the id back to the tool.
  static const defaultChatAgent = 'hermes';

  /// No remembered selection yet — the state before the first launch that saves.
  static const empty = ChatPrefs();

  final String? networkId;
  final String? model;

  /// What the agent may do without asking. Deliberately remembered: a user who
  /// turned the asking off shouldn't have it turned back on behind their back —
  /// and one who never touched it stays on [AgentApprovalMode.ask].
  final AgentApprovalMode approval;

  /// The Light/Dark/System choice. Defaults to [ThemeMode.light] — the app ships
  /// light, and a user who never touched it stays there.
  final ThemeMode themeMode;

  /// Which installed agent answers chats — its id (`hermes`, `codex`). Remembered
  /// so a user who picked Codex keeps it across launches; an unknown or
  /// no-longer-installed id falls back to whatever is installed.
  final String chatAgent;

  ChatPrefs copyWith({
    String? networkId,
    String? model,
    AgentApprovalMode? approval,
    ThemeMode? themeMode,
    String? chatAgent,
  }) => ChatPrefs(
    networkId: networkId ?? this.networkId,
    model: model ?? this.model,
    approval: approval ?? this.approval,
    themeMode: themeMode ?? this.themeMode,
    chatAgent: chatAgent ?? this.chatAgent,
  );

  factory ChatPrefs.fromJson(Map<String, dynamic> json) => ChatPrefs(
    networkId: json['networkId'] as String?,
    model: json['model'] as String?,
    approval: _approvalFrom(json['approval']),
    themeMode: _themeModeFrom(json['themeMode']),
    chatAgent: json['chatAgent'] as String? ?? defaultChatAgent,
  );

  Map<String, Object?> toJson() => {
    'networkId': networkId,
    'model': model,
    'approval': approval.name,
    'themeMode': themeMode.name,
    'chatAgent': chatAgent,
  };

  /// A missing or unrecognised value reads as "ask" — a hand-edited file must
  /// never quietly hand the agent more than the user granted.
  static AgentApprovalMode _approvalFrom(Object? raw) {
    for (final mode in AgentApprovalMode.values) {
      if (mode.name == raw) return mode;
    }
    return AgentApprovalMode.ask;
  }

  /// A missing or unrecognised value reads as [ThemeMode.light] — the app's
  /// shipped default, so a corrupt/hand-edited file never lands somewhere odd.
  static ThemeMode _themeModeFrom(Object? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return ThemeMode.light;
  }

  @override
  bool operator ==(Object other) =>
      other is ChatPrefs &&
      other.networkId == networkId &&
      other.model == model &&
      other.approval == approval &&
      other.themeMode == themeMode;

  @override
  int get hashCode => Object.hash(networkId, model, approval, themeMode);
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
/// Written from the two places that own a piece of it — the grid switcher
/// ([selectedNetworkProvider]) and the model picker — but read back as one
/// object.
final chatPrefsProvider = NotifierProvider<ChatPrefsController, ChatPrefs>(
  ChatPrefsController.new,
);

class ChatPrefsController extends Notifier<ChatPrefs> {
  @override
  ChatPrefs build() => ref.read(chatPrefsStoreProvider).load();

  void setNetwork(String networkId) =>
      _update(state.copyWith(networkId: networkId));

  void setModel(String model) => _update(state.copyWith(model: model));

  void setApproval(AgentApprovalMode approval) =>
      _update(state.copyWith(approval: approval));

  void setChatAgent(String id) => _update(state.copyWith(chatAgent: id));

  void setThemeMode(ThemeMode mode) => _update(state.copyWith(themeMode: mode));

  void _update(ChatPrefs next) {
    if (next == state) return;
    state = next;
    ref.read(chatPrefsStoreProvider).save(next);
  }
}

/// The remembered Light/Dark/System choice, as its own read-only slice so the app
/// root can watch just the theme without rebuilding on every chat-pref change.
/// Defaults to [ThemeMode.light].
final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(chatPrefsProvider).themeMode,
);
