// Manual probe: drives the real `hermes acp` binary through
// HermesAcpServiceImpl to confirm the persistent-session lifecycle — one
// process, handshake once, two prompts, clean close. Run:
//   dart run tool/hermes_acp_probe.dart
// Not a unit test (needs the hermes binary + network); kept for hand-verifying
// the ACP plumbing after changes.
import 'dart:async';
import 'dart:io';

import 'package:grid_app/infrastructure/cli/host_environment.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_service.dart';

Future<void> main() async {
  final path = HostEnvironment.findExecutable('hermes');
  if (path == null) {
    stderr.writeln('hermes not found on PATH');
    exit(1);
  }
  stdout.writeln('hermes: $path');

  final workdir = Directory.systemTemp.createTempSync('hermes_acp_probe').path;
  final service = HermesAcpServiceImpl(path);

  final HermesAcpSession session;
  try {
    session = await service
        .start(workdir: workdir)
        .timeout(const Duration(seconds: 20));
  } on Object catch (e) {
    stderr.writeln('handshake FAILED: $e');
    exit(1);
  }
  stdout.writeln('handshake OK — session is live (isClosed=${session.isClosed})');

  await _runTurn(session, 'Say the single word: ping', label: 'turn 1');
  stdout.writeln('after turn 1: isClosed=${session.isClosed} (must be false)');

  await _runTurn(session, 'Say the single word: pong', label: 'turn 2');
  stdout.writeln('after turn 2: isClosed=${session.isClosed} (must be false)');

  await session.close();
  stdout.writeln('closed: isClosed=${session.isClosed} (must be true)');
  exit(0);
}

Future<void> _runTurn(
  HermesAcpSession session,
  String text, {
  required String label,
}) async {
  final answer = StringBuffer();
  final run = session.prompt(text);
  final sub = run.events.listen((event) {
    switch (event) {
      case HermesAcpMessage(:final text):
        answer.write(text);
        stdout.write(text);
      case HermesAcpActivity(:final activity):
        stdout.writeln('\n[tool ${activity.label} ${activity.status.name}]');
      case HermesAcpEdit(:final request):
        // Auto-applied edit (no approval needed); just note it for the probe.
        stdout.writeln('\n[edit applied: ${request.summary}]');
      case HermesAcpPermission(:final request):
        // The probe's prompts don't escalate; if one ever does, cancel it so the
        // turn doesn't stall waiting on an answer that never comes.
        stdout.writeln('\n[permission requested: ${request.summary} — cancelling]');
        session.answerPermission(request.id, null);
    }
  });
  try {
    await run.done.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    stderr.writeln('\n$label TIMED OUT');
    run.kill();
  }
  await sub.cancel();
  stdout.writeln('\n$label reply: "${answer.toString().trim()}"');
}
