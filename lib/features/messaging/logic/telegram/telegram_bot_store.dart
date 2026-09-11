import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/grid_paths.dart';
import '../../../../core/owner_only_file.dart';

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
  });

  /// The token @BotFather gave out. A password: it is never logged or shown.
  final String token;

  /// The Telegram user ids that may message the bot. Never empty — Grid won't
  /// connect a bot that would answer anyone who found it.
  final List<String> allowedUsers;

  /// The bot's username, without the `@` — what the person searches for.
  final String botName;

  /// Telegram chat id → the Grid chat it is carrying on. `/new` points a chat
  /// at a fresh one; the old one stays in Chat.
  final Map<String, String> threads;

  /// The Grid chat Telegram chat [chatId] is carrying on, if it has one.
  String? threadFor(int chatId) => threads['$chatId'];

  TelegramBotConfig withThread(int chatId, String conversationId) =>
      TelegramBotConfig(
        token: token,
        allowedUsers: allowedUsers,
        botName: botName,
        threads: Map.unmodifiable({...threads, '$chatId': conversationId}),
      );

  Map<String, Object?> toJson() => {
    'token': token,
    'allowed_users': allowedUsers,
    'bot_name': botName,
    'threads': threads,
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
    final threads = raw['threads'];
    return TelegramBotConfig(
      token: token,
      allowedUsers: List.unmodifiable(allowed),
      botName: name is String ? name : '',
      threads: Map.unmodifiable({
        if (threads is Map)
          for (final entry in threads.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      }),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TelegramBotConfig &&
      other.token == token &&
      other.botName == botName &&
      listEquals(other.allowedUsers, allowedUsers) &&
      mapEquals(other.threads, threads);

  @override
  int get hashCode => Object.hash(
    token,
    botName,
    Object.hashAll(allowedUsers),
    Object.hashAllUnordered(threads.entries.map((e) => '${e.key}=${e.value}')),
  );
}

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
