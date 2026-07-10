import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'codex_event.dart';
import 'host_environment.dart';

/// One thing to show from a running Hermes ACP turn: a tool step for the
/// activity feed, or a chunk of the streamed answer.
sealed class HermesAcpEvent {
  const HermesAcpEvent();
}

/// A shell command or tool call the agent ran — reuses [CodexActivity] so the
/// Chat tab's activity feed is identical across codex and hermes.
class HermesAcpActivity extends HermesAcpEvent {
  const HermesAcpActivity(this.activity);
  final CodexActivity activity;
}

/// A chunk of the assistant's answer, streamed as it's generated.
class HermesAcpMessage extends HermesAcpEvent {
  const HermesAcpMessage(this.text);
  final String text;
}

/// A handle to a running `hermes acp` prompt turn: its parsed events, a future
/// that completes when the turn ends, and a kill switch.
class HermesAcpRun {
  const HermesAcpRun({
    required this.events,
    required this.done,
    required this.kill,
  });

  final Stream<HermesAcpEvent> events;
  final Future<void> done;
  final void Function() kill;
}

/// The seam between the app and `hermes acp` — Hermes's Agent Client Protocol
/// (newline-delimited JSON-RPC over stdio). Behind an interface so the sender is
/// tested against a fake that replays scripted events.
///
/// ACP is used instead of `hermes -z` because `-z` prints only the final answer
/// ("no tool previews"), whereas ACP streams `tool_call` / `tool_call_update`
/// and `agent_message_chunk` updates — so the Chat tab can show what the agent
/// is doing, live.
abstract interface class HermesAcpService {
  HermesAcpRun prompt({required String text, required String workdir});
}

/// Real implementation: spawns `hermes acp`, runs the
/// initialize → session/new → session/prompt handshake, auto-approves the
/// agent's permission requests, and maps `session/update` notifications to
/// [HermesAcpEvent]s.
class HermesAcpServiceImpl implements HermesAcpService {
  const HermesAcpServiceImpl(this._path);

  final String _path;

  @override
  HermesAcpRun prompt({required String text, required String workdir}) {
    final events = StreamController<HermesAcpEvent>();
    final done = Completer<void>();
    // Kind/title only arrive on the initial tool_call; remember them so a later
    // tool_call_update (which carries just id + status) keeps its label.
    final tools = <String, CodexActivity>{};
    Process? process;

    // Flush after each line: hermes reads newline-delimited JSON-RPC from stdin,
    // and an unflushed buffer would leave it waiting for input while we wait for
    // its output — a deadlock. Writes are response-driven (never concurrent), so
    // fire-and-forget flushes don't overlap.
    void write(Map<String, Object?> message) {
      final stdin = process?.stdin;
      if (stdin == null) return;
      stdin.write('${jsonEncode(message)}\n');
      stdin.flush().ignore();
    }

    void handleUpdate(Object? raw) {
      if (raw is! Map) return;
      switch (raw['sessionUpdate']) {
        case 'tool_call':
          final id = _str(raw['toolCallId']);
          final activity = CodexActivity(
            id: id,
            kind: raw['kind'] == 'execute'
                ? CodexActivityKind.command
                : CodexActivityKind.tool,
            label: _str(raw['title'], fallback: 'tool'),
            status: CodexActivityStatus.running,
          );
          tools[id] = activity;
          events.add(HermesAcpActivity(activity));
        case 'tool_call_update':
          final id = _str(raw['toolCallId']);
          final prior = tools[id];
          final activity = CodexActivity(
            id: id,
            kind: prior?.kind ?? CodexActivityKind.tool,
            label: prior?.label ?? 'tool',
            status: _status(raw['status']),
          );
          tools[id] = activity;
          events.add(HermesAcpActivity(activity));
        case 'agent_message_chunk':
          final content = raw['content'];
          if (content is Map && content['text'] is String) {
            events.add(HermesAcpMessage(content['text'] as String));
          }
      }
    }

    // Server → client requests: auto-approve permission prompts (the agent runs
    // read-only), acknowledge everything else with an empty result.
    void respond(Map<String, dynamic> message) {
      Object result = const <String, Object?>{};
      final method = message['method'];
      if (method is String && method.contains('permission')) {
        final options = message['params']?['options'];
        final optionId = options is List && options.isNotEmpty
            ? _str((options.first as Map)['optionId'], fallback: 'allow')
            : 'allow';
        result = {
          'outcome': {'outcome': 'selected', 'optionId': optionId},
        };
      }
      write({'jsonrpc': '2.0', 'id': message['id'], 'result': result});
    }

    void handle(Map<String, dynamic> message) {
      if (message['method'] == 'session/update') {
        handleUpdate(message['params']?['update']);
        return;
      }
      if (message['method'] != null && message['id'] != null) {
        respond(message);
        return;
      }
      switch (message['id']) {
        case 0:
          write({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'session/new',
            'params': {'cwd': workdir, 'mcpServers': const []},
          });
        case 1:
          final sessionId = message['result']?['sessionId'];
          write({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'session/prompt',
            'params': {
              'sessionId': sessionId,
              'prompt': [
                {'type': 'text', 'text': text},
              ],
            },
          });
        case 2:
          process?.kill();
      }
    }

    Future<void> run() async {
      try {
        process = await Process.start(
          _path,
          ['acp'],
          workingDirectory: workdir,
          environment: {
            ...Platform.environment,
            'PATH': HostEnvironment.path(),
          },
        );
      } on ProcessException {
        await events.close();
        if (!done.isCompleted) done.complete();
        return;
      }

      write({
        'jsonrpc': '2.0',
        'id': 0,
        'method': 'initialize',
        'params': {
          'protocolVersion': 1,
          'clientCapabilities': {
            'fs': {'readTextFile': false, 'writeTextFile': false},
          },
        },
      });

      final stdoutDone = process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            final decoded = _tryDecode(line);
            if (decoded != null) handle(decoded);
          });
      final stderrDone = process!.stderr.transform(utf8.decoder).drain<void>();

      await process!.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      await events.close();
      if (!done.isCompleted) done.complete();
    }

    unawaited(run());

    return HermesAcpRun(
      events: events.stream,
      done: done.future,
      kill: () => process?.kill(),
    );
  }
}

Map<String, dynamic>? _tryDecode(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

CodexActivityStatus _status(Object? raw) => switch (raw) {
  'failed' => CodexActivityStatus.failed,
  'in_progress' || 'pending' => CodexActivityStatus.running,
  _ => CodexActivityStatus.done,
};

String _str(Object? raw, {String fallback = ''}) =>
    raw is String ? raw : fallback;
