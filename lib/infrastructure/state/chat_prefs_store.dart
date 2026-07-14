import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../cli/agent_event.dart';

/// The chat's remembered selections — the grid and the model the user last used,
/// and how much they let the agent do — so reopening the app restores them
/// instead of resetting to defaults. The grid and model are null until first
/// picked; [approval] always has a value, and its default is the cautious one.
class ChatPrefs {
  const ChatPrefs({
    this.networkId,
    this.model,
    this.approval = AgentApprovalMode.ask,
  });

  /// No remembered selection yet — the state before the first launch that saves.
  static const empty = ChatPrefs();

  final String? networkId;
  final String? model;

  /// What the agent may do without asking. Deliberately remembered: a user who
  /// turned the asking off shouldn't have it turned back on behind their back —
  /// and one who never touched it stays on [AgentApprovalMode.ask].
  final AgentApprovalMode approval;

  ChatPrefs copyWith({
    String? networkId,
    String? model,
    AgentApprovalMode? approval,
  }) => ChatPrefs(
    networkId: networkId ?? this.networkId,
    model: model ?? this.model,
    approval: approval ?? this.approval,
  );

  factory ChatPrefs.fromJson(Map<String, dynamic> json) => ChatPrefs(
    networkId: json['networkId'] as String?,
    model: json['model'] as String?,
    approval: _approvalFrom(json['approval']),
  );

  Map<String, Object?> toJson() => {
    'networkId': networkId,
    'model': model,
    'approval': approval.name,
  };

  /// A missing or unrecognised value reads as "ask" — a hand-edited file must
  /// never quietly hand the agent more than the user granted.
  static AgentApprovalMode _approvalFrom(Object? raw) {
    for (final mode in AgentApprovalMode.values) {
      if (mode.name == raw) return mode;
    }
    return AgentApprovalMode.ask;
  }

  @override
  bool operator ==(Object other) =>
      other is ChatPrefs &&
      other.networkId == networkId &&
      other.model == model &&
      other.approval == approval;

  @override
  int get hashCode => Object.hash(networkId, model, approval);
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

  void _update(ChatPrefs next) {
    if (next == state) return;
    state = next;
    ref.read(chatPrefsStoreProvider).save(next);
  }
}
