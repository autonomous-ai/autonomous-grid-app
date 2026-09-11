import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/grid_paths.dart';
import '../../../../core/owner_only_file.dart';

/// A chat `/new` or `/sessions` set up that hasn't had its first message yet:
/// the project it belongs in, and a model picked for it with `/model`.
///
/// The Grid chat itself is only made when that first message arrives, so
/// tapping around the menus leaves no empty chats behind in the sidebar — the
/// same "not started yet" a new thread has in dev-quen-bots.
typedef TelegramDraft = ({String? projectId, String? model});

/// The bot Grid answers as, who may use it, and which Grid chat each Telegram
/// chat is carrying on.
///
/// Carries `==` because it is held in provider state (conventions §2): it is
/// re-read from disk, and an unchanged file must not read as a change.
class TelegramBotConfig {
  const TelegramBotConfig({
    required this.token,
    required this.allowedUsers,
    required this.botName,
    this.threads = const {},
    this.drafts = const {},
  });

  /// The token @BotFather gave out. A password: it is never logged or shown.
  final String token;

  /// The Telegram user ids that may message the bot. Never empty — Grid won't
  /// connect a bot that would answer anyone who found it.
  final List<String> allowedUsers;

  /// The bot's username, without the `@` — what the person searches for.
  final String botName;

  /// Telegram chat id → the Grid chat it is carrying on. `/new` and
  /// `/sessions` point a chat elsewhere; the old one stays in Chat.
  final Map<String, String> threads;

  /// Grid chat id → the [TelegramDraft] of a chat not started yet.
  final Map<String, TelegramDraft> drafts;

  /// The Grid chat Telegram chat [chatId] is carrying on, if it has one.
  String? threadFor(int chatId) => threads['$chatId'];

  /// The draft behind [conversationId], if that chat hasn't started yet.
  TelegramDraft? draftFor(String conversationId) => drafts[conversationId];

  /// Point Telegram chat [chatId] at [conversationId] — with a [draft] when it
  /// is a chat still to be started.
  ///
  /// A draft the chat is leaving goes with it: nothing was ever said in it, so
  /// there is nothing to come back to, and it would otherwise sit in the file
  /// for good.
  TelegramBotConfig withThread(
    int chatId,
    String conversationId, {
    TelegramDraft? draft,
  }) {
    final leaving = threads['$chatId'];
    final kept = {
      for (final entry in drafts.entries)
        if (entry.key != leaving) entry.key: entry.value,
    };
    return _copy(
      threads: {...threads, '$chatId': conversationId},
      drafts: draft == null ? kept : {...kept, conversationId: draft},
    );
  }

  TelegramBotConfig withDraft(String conversationId, TelegramDraft draft) =>
      _copy(drafts: {...drafts, conversationId: draft});

  /// Forget [conversationId]'s draft — it has started, and the Grid chat now
  /// holds its project and model itself.
  TelegramBotConfig withoutDraft(String conversationId) => _copy(
    drafts: {
      for (final entry in drafts.entries)
        if (entry.key != conversationId) entry.key: entry.value,
    },
  );

  TelegramBotConfig _copy({
    Map<String, String>? threads,
    Map<String, TelegramDraft>? drafts,
  }) => TelegramBotConfig(
    token: token,
    allowedUsers: allowedUsers,
    botName: botName,
    threads: Map.unmodifiable(threads ?? this.threads),
    drafts: Map.unmodifiable(drafts ?? this.drafts),
  );

  Map<String, Object?> toJson() => {
    'token': token,
    'allowed_users': allowedUsers,
    'bot_name': botName,
    'threads': threads,
    'drafts': {
      for (final entry in drafts.entries)
        entry.key: {
          'project': ?entry.value.projectId,
          'model': ?entry.value.model,
        },
    },
  };

  /// A config, or null when [raw] lacks the token or anyone to answer — a bot
  /// Grid couldn't run safely is the same as no bot.
  static TelegramBotConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final users = raw['allowed_users'];
    if (token is! String || token.isEmpty || users is! List) return null;
    final allowed = [
      for (final id in users)
        if (id is String && id.trim().isNotEmpty) id.trim(),
    ];
    if (allowed.isEmpty) return null;
    final name = raw['bot_name'];
    return TelegramBotConfig(
      token: token,
      allowedUsers: List.unmodifiable(allowed),
      botName: name is String ? name : '',
      threads: Map.unmodifiable(_strings(raw['threads'])),
      drafts: Map.unmodifiable(_drafts(raw['drafts'])),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TelegramBotConfig &&
      other.token == token &&
      other.botName == botName &&
      listEquals(other.allowedUsers, allowedUsers) &&
      mapEquals(other.threads, threads) &&
      mapEquals(other.drafts, drafts);

  @override
  int get hashCode => Object.hash(
    token,
    botName,
    Object.hashAll(allowedUsers),
    Object.hashAllUnordered(threads.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAllUnordered(drafts.entries.map((e) => '${e.key}=${e.value}')),
  );
}

Map<String, String> _strings(Object? raw) => {
  if (raw is Map)
    for (final entry in raw.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
};

Map<String, TelegramDraft> _drafts(Object? raw) => {
  if (raw is Map)
    for (final entry in raw.entries)
      if (entry.key is String && entry.value is Map)
        entry.key as String: (
          projectId: _stringOrNull((entry.value as Map)['project']),
          model: _stringOrNull((entry.value as Map)['model']),
        ),
};

String? _stringOrNull(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

/// `~/.grid/app/telegram_bot.json`, mode `600` — see
/// [GridPaths.telegramBotFile].
class TelegramBotStore {
  TelegramBotStore({File? file}) : _file = file;

  /// Overridable so tests write into a temp dir and never touch `~/.grid`.
  final File? _file;

  File get file => _file ?? GridPaths.telegramBotFile;

  /// The saved bot, or null when there is none. A file that won't parse reads
  /// as no bot rather than an error: the screen that could fix it must open.
  Future<TelegramBotConfig?> read() async {
    if (!await file.exists()) return null;
    try {
      return TelegramBotConfig.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  /// Save [config] through a temporary file, locked down *before* it takes the
  /// real name — so the token is never briefly readable by others, and a crash
  /// mid-write can't leave half a file that reads as "no bot".
  Future<void> write(TelegramBotConfig config) async {
    await file.parent.create(recursive: true);
    final staging = File('${file.path}.tmp');
    await staging.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
    await restrictToOwner(staging);
    await staging.rename(file.path);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}

final telegramBotStoreProvider = Provider<TelegramBotStore>(
  (ref) => TelegramBotStore(),
);
