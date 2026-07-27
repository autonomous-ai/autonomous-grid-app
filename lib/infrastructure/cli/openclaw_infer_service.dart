import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// How long a single OpenClaw turn may run before it's given up on. One-shot
/// inference isn't interactive, but a wedged provider must not hang the chat.
const Duration kOpenClawTurnTimeout = Duration(minutes: 5);

/// Argv for a one-shot OpenClaw inference:
/// `openclaw infer model run --prompt <text> --model <provider>/<model> --json`.
///
/// OpenClaw's CLI (`docs.openclaw.ai/cli/infer`) exposes neither a streaming nor
/// a resume flag here, so a turn is a single JSON object and continuity is the
/// caller's job — the whole conversation is replayed in [prompt] each time.
/// [model] is a `provider/model` id (Grid writes a `grid` provider into
/// `openclaw.json`, so it's `grid/<model>`).
///
/// Pure and unit-tested: a mistyped flag fails exactly like a model that
/// wouldn't answer, so the argv is assembled somewhere a test can see it.
List<String> openClawInferArgs({
  required String prompt,
  required String model,
}) => ['infer', 'model', 'run', '--prompt', prompt, '--model', model, '--json'];

/// Pulls the assistant's reply out of OpenClaw's `--json` envelope, or null when
/// there's nothing usable in it.
///
/// The envelope is `{ok, capability, provider, model, outputs: [...], ...}`. The
/// reply lives in `outputs`; the docs don't pin its element shape, so this reads
/// the shapes a text reply plausibly takes (a bare string, or a map carrying
/// `text`/`content`/`message`) and joins them.
/// TODO(BE): confirm the exact `outputs` element shape against a live
/// `openclaw infer model run --json` and tighten this — it's inferred from the
/// docs, not a real transcript, which is why OpenClaw ships developer-only.
String? parseOpenClawReply(String stdout) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['ok'] == false) return null;
  final outputs = decoded['outputs'];
  if (outputs is! List) return null;
  final parts = <String>[];
  for (final output in outputs) {
    if (output is String) {
      parts.add(output);
      continue;
    }
    if (output is Map) {
      final text = output['text'] ?? output['content'] ?? output['message'];
      if (text is String) parts.add(text);
    }
  }
  final joined = parts.join('\n').trim();
  return joined.isEmpty ? null : joined;
}

/// A turn in flight: [reply] completes with the assistant text (or throws an
/// [OpenClawInferException]), and [kill] tears the process down when the user
/// stops or leaves.
class OpenClawInferRun {
  const OpenClawInferRun({required this.reply, required this.kill});
  final Future<String> reply;
  final void Function() kill;
}

/// Why an OpenClaw turn couldn't produce an answer. [retryable] is true only for
/// a failure to *start* the process — where sending again might work.
class OpenClawInferException implements Exception {
  const OpenClawInferException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;

  @override
  String toString() => 'OpenClawInferException: $message';
}

/// Drives `openclaw infer` for one chat turn.
abstract interface class OpenClawInferService {
  /// Run [prompt] against [model] in [workdir], resolving to the reply text.
  OpenClawInferRun run({
    required String prompt,
    required String model,
    required String workdir,
  });
}

/// Real implementation: spawns `openclaw infer model run --json`, buffers its
/// output (a turn is one JSON object, not a stream), and resolves the reply on a
/// clean exit — or throws the CLI's own last words.
class OpenClawInferServiceImpl implements OpenClawInferService {
  const OpenClawInferServiceImpl(this._path);

  final String _path;

  @override
  OpenClawInferRun run({
    required String prompt,
    required String model,
    required String workdir,
  }) {
    final completer = Completer<String>();
    Process? process;
    var killed = false;

    void kill() {
      killed = true;
      process?.kill();
    }

    Process.start(
          _path,
          openClawInferArgs(prompt: prompt, model: model),
          workingDirectory: workdir,
          environment: {
            ...Platform.environment,
            'PATH': HostEnvironment.path(),
          },
        )
        .then((started) async {
          if (killed) {
            started.kill();
            return;
          }
          process = started;
          final stdout = await started.stdout.transform(utf8.decoder).join();
          final stderr = await started.stderr.transform(utf8.decoder).join();
          final code = await started.exitCode;
          if (killed || completer.isCompleted) return;
          final complaint = stderr.trim();
          if (code != 0) {
            // The whole complaint, not its last line: OpenClaw's node-version
            // refusal ends in a bare `nvm alias default 24`, so the last line is
            // the least useful thing on it. The humanizer reads the first line.
            completer.completeError(
              OpenClawInferException(
                complaint.isEmpty ? 'exited with code $code' : complaint,
              ),
            );
            return;
          }
          final reply = parseOpenClawReply(stdout);
          if (reply == null) {
            completer.completeError(
              OpenClawInferException(
                complaint.isEmpty ? 'it returned no text.' : complaint,
              ),
            );
            return;
          }
          completer.complete(reply);
        })
        .catchError((Object error) {
          if (killed || completer.isCompleted) return;
          completer.completeError(
            OpenClawInferException(
              "Couldn't start OpenClaw: $error",
              retryable: true,
            ),
          );
        });

    final reply = completer.future.timeout(
      kOpenClawTurnTimeout,
      onTimeout: () {
        kill();
        throw const OpenClawInferException('it took too long to answer.');
      },
    );
    return OpenClawInferRun(reply: reply, kill: kill);
  }
}
