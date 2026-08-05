import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../cli/agent_event.dart';

/// The chat's remembered selections — the grid and the model the user last used,
/// how much they let the agent do, which theme they chose, and how they want the
/// app's type set — so reopening the app restores them instead of resetting to
/// defaults. The grid, model and both font families are null until first picked;
/// [approval], [themeMode] and the two font sizes always have a value.
class ChatPrefs {
  const ChatPrefs({
    this.networkId,
    this.model,
    this.approval = AgentApprovalMode.full,
    this.detail = AgentDetailMode.stepsCommands,
    this.themeMode = ThemeMode.light,
    this.chatAgent = defaultChatAgent,
    this.uiFontFamily,
    this.codeFontFamily,
    this.uiFontSize = defaultUiFontSize,
    this.codeFontSize = defaultCodeFontSize,
  });

  /// The base UI size the app was drawn at, and the number every other size
  /// scales against. Matches the text theme's `bodyMedium` and the figure a user
  /// coming from Codex will recognise (its `sansFontSize` also defaults to 14).
  static const double defaultUiFontSize = 14;

  /// Code's own size, independent of the UI scale — 12.5 is what the chat's code
  /// blocks and the markdown sheet were already drawn at.
  static const double defaultCodeFontSize = 12.5;

  /// The range the UI may be scaled through.
  ///
  /// Not a matter of taste: the app's controls are fixed-height boxes
  /// (`AppControl.height` 32, `heightField` 36) sized to a 13pt label, and past
  /// roughly ±35% a label stops fitting the box it sits in. The bounds are what
  /// the layout can absorb, verified by measuring a button and a field at both
  /// ends — see `test/shared/font_scale_test.dart`.
  static const double minUiFontSize = 11;
  static const double maxUiFontSize = 19;

  /// Code's range. Wider at the bottom than the UI's: a code block is a
  /// self-contained box that can go smaller without dragging a row's geometry
  /// with it.
  static const double minCodeFontSize = 9;
  static const double maxCodeFontSize = 22;

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
  /// dialled the access back shouldn't have it widened behind their back — and
  /// one who never touched it starts on [AgentApprovalMode.full], free to run
  /// commands and change files without stopping to ask.
  final AgentApprovalMode approval;

  /// How much of the agent's working-out a chat shows. Defaults to the fullest
  /// view, which is what the app showed before the setting existed — a user who
  /// never opens Appearance sees exactly what they saw yesterday, and the two
  /// quieter levels are there for the ones who want them.
  final AgentDetailMode detail;

  /// The Light/Dark/System choice. Defaults to [ThemeMode.light] — the app ships
  /// light, and a user who never touched it stays there.
  final ThemeMode themeMode;

  /// Which installed agent answers chats — its id (`hermes`, `codex`). Remembered
  /// so a user who picked Codex keeps it across launches; an unknown or
  /// no-longer-installed id falls back to whatever is installed.
  final String chatAgent;

  /// The family the UI is set in, or null for the system font.
  ///
  /// Null is a real value here, not a missing one: it means "whatever this Mac's
  /// system font is", which is what the app ships with and what keeps it looking
  /// native. A name is stored exactly as the font manager reports it, because
  /// that string is what CoreText resolves against.
  final String? uiFontFamily;

  /// The family code is set in, or null for the system monospace font.
  final String? codeFontFamily;

  /// Base UI size in logical pixels. Everything else scales against
  /// [defaultUiFontSize], so this is a *scale* expressed as a size — the number
  /// the user actually thinks in.
  final double uiFontSize;

  /// Code's size in logical pixels, applied absolutely: a code block does not
  /// also take the UI scale, or the two would multiply.
  final double codeFontSize;

  ChatPrefs copyWith({
    String? networkId,
    String? model,
    AgentApprovalMode? approval,
    AgentDetailMode? detail,
    ThemeMode? themeMode,
    String? chatAgent,
    String? uiFontFamily,
    String? codeFontFamily,
    double? uiFontSize,
    double? codeFontSize,
    bool clearUiFontFamily = false,
    bool clearCodeFontFamily = false,
  }) => ChatPrefs(
    networkId: networkId ?? this.networkId,
    model: model ?? this.model,
    approval: approval ?? this.approval,
    detail: detail ?? this.detail,
    themeMode: themeMode ?? this.themeMode,
    chatAgent: chatAgent ?? this.chatAgent,
    // The `?? this.x` idiom can't express "back to the system font" — passing
    // null reads as "leave it alone" — so going back to the default needs a flag
    // of its own. Same shape as `clearArchivedAt` on Conversation, and for the
    // same reason: without it, "System" would silently do nothing.
    uiFontFamily: clearUiFontFamily
        ? null
        : (uiFontFamily ?? this.uiFontFamily),
    codeFontFamily: clearCodeFontFamily
        ? null
        : (codeFontFamily ?? this.codeFontFamily),
    uiFontSize: uiFontSize ?? this.uiFontSize,
    codeFontSize: codeFontSize ?? this.codeFontSize,
  );

  factory ChatPrefs.fromJson(Map<String, dynamic> json) => ChatPrefs(
    networkId: json['networkId'] as String?,
    model: json['model'] as String?,
    approval: _approvalFrom(json['approval']),
    detail: _detailFrom(json['detail']),
    themeMode: _themeModeFrom(json['themeMode']),
    chatAgent: json['chatAgent'] as String? ?? defaultChatAgent,
    uiFontFamily: _familyFrom(json['uiFontFamily']),
    codeFontFamily: _familyFrom(json['codeFontFamily']),
    uiFontSize: _sizeFrom(
      json['uiFontSize'],
      fallback: defaultUiFontSize,
      min: minUiFontSize,
      max: maxUiFontSize,
    ),
    codeFontSize: _sizeFrom(
      json['codeFontSize'],
      fallback: defaultCodeFontSize,
      min: minCodeFontSize,
      max: maxCodeFontSize,
    ),
  );

  Map<String, Object?> toJson() => {
    'networkId': networkId,
    'model': model,
    'approval': approval.name,
    'detail': detail.name,
    'themeMode': themeMode.name,
    'chatAgent': chatAgent,
    'uiFontFamily': uiFontFamily,
    'codeFontFamily': codeFontFamily,
    'uiFontSize': uiFontSize,
    'codeFontSize': codeFontSize,
  };

  /// A family name, or null for "system font".
  ///
  /// An empty or blank string is *not* a font — CoreText resolves it to nothing
  /// and the text disappears — so it reads as the default rather than being
  /// handed to the engine.
  static String? _familyFrom(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// A size, clamped into range. A hand-edited or corrupt file must not be able
  /// to set a size that renders the app unusable — including one it would then
  /// be too broken to fix the setting from.
  static double _sizeFrom(
    Object? raw, {
    required double fallback,
    required double min,
    required double max,
  }) {
    final value = raw is num ? raw.toDouble() : null;
    // NaN fails every comparison, so it would slip past a bare clamp.
    if (value == null || value.isNaN || value.isInfinite) return fallback;
    return value.clamp(min, max);
  }

  /// A missing or unrecognised value in an existing file reads as "ask" — not
  /// the Full a brand-new install ([ChatPrefs.empty]) starts on: a hand-edited
  /// or corrupt file must never quietly hand the agent more than was granted.
  /// An unknown name (a level this build has dropped) falls back to the
  /// default rather than hiding the feed.
  static AgentDetailMode _detailFrom(Object? raw) {
    for (final mode in AgentDetailMode.values) {
      if (mode.name == raw) return mode;
    }
    return AgentDetailMode.stepsCommands;
  }

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
      other.detail == detail &&
      other.themeMode == themeMode &&
      other.chatAgent == chatAgent &&
      other.uiFontFamily == uiFontFamily &&
      other.codeFontFamily == codeFontFamily &&
      other.uiFontSize == uiFontSize &&
      other.codeFontSize == codeFontSize;

  @override
  int get hashCode => Object.hash(
    networkId,
    model,
    approval,
    detail,
    themeMode,
    chatAgent,
    uiFontFamily,
    codeFontFamily,
    uiFontSize,
    codeFontSize,
  );
}

/// Just the type settings, split out of [ChatPrefs] so the app root can watch
/// the four values that rebuild the whole theme without also waking on every
/// model or grid selection.
class FontPrefs {
  const FontPrefs({
    this.uiFamily,
    this.codeFamily,
    this.uiSize = ChatPrefs.defaultUiFontSize,
    this.codeSize = ChatPrefs.defaultCodeFontSize,
  });

  final String? uiFamily;
  final String? codeFamily;
  final double uiSize;
  final double codeSize;

  /// What every UI size is multiplied by. Expressed against the size the app was
  /// drawn at, so 1.0 is exactly the shipped look.
  double get uiScale => uiSize / ChatPrefs.defaultUiFontSize;

  @override
  bool operator ==(Object other) =>
      other is FontPrefs &&
      other.uiFamily == uiFamily &&
      other.codeFamily == codeFamily &&
      other.uiSize == uiSize &&
      other.codeSize == codeSize;

  @override
  int get hashCode => Object.hash(uiFamily, codeFamily, uiSize, codeSize);
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

  void setDetail(AgentDetailMode detail) =>
      _update(state.copyWith(detail: detail));

  void setChatAgent(String id) => _update(state.copyWith(chatAgent: id));

  void setThemeMode(ThemeMode mode) => _update(state.copyWith(themeMode: mode));

  /// Set the UI font family; null puts it back on the system font.
  void setUiFontFamily(String? family) => _update(
    state.copyWith(uiFontFamily: family, clearUiFontFamily: family == null),
  );

  /// Set the code font family; null puts it back on the system monospace font.
  void setCodeFontFamily(String? family) => _update(
    state.copyWith(codeFontFamily: family, clearCodeFontFamily: family == null),
  );

  /// Both sizes clamp on the way in, not only on the way out of the file: the
  /// settings field lets a user type any number, and the value that reaches the
  /// theme has to be one the layout can hold.
  void setUiFontSize(double size) => _update(
    state.copyWith(
      uiFontSize: size.clamp(ChatPrefs.minUiFontSize, ChatPrefs.maxUiFontSize),
    ),
  );

  void setCodeFontSize(double size) => _update(
    state.copyWith(
      codeFontSize: size.clamp(
        ChatPrefs.minCodeFontSize,
        ChatPrefs.maxCodeFontSize,
      ),
    ),
  );

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

/// The remembered type settings, as their own slice for the same reason
/// [themeModeProvider] is one: changing a model must not rebuild every theme in
/// the app, and changing a font must.
final fontPrefsProvider = Provider<FontPrefs>((ref) {
  final prefs = ref.watch(chatPrefsProvider);
  return FontPrefs(
    uiFamily: prefs.uiFontFamily,
    codeFamily: prefs.codeFontFamily,
    uiSize: prefs.uiFontSize,
    codeSize: prefs.codeFontSize,
  );
});
