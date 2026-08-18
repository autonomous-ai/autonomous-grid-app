import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/host_environment.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/skills/agent_skill_home.dart';
import 'agent_catalog.dart';
import 'grid_serve_skill.dart';

/// Something the assistant started on this computer and left running.
///
/// The `grid-serve` skill exists because a dev server started inside a tool call
/// dies with it, so it hands the process to launchd/screen/tmux and writes a
/// record. That solved the hard half and left the visible one: the process
/// outlives the turn, outlives the chat, and outlives the app — with nothing on
/// screen saying it is there. "What is my computer running?" had no answer
/// inside the app, which is a question about honesty (§5), not convenience.
class ServedService {
  const ServedService({
    required this.name,
    required this.command,
    required this.directory,
    required this.startedAt,
    this.port,
    this.logPath,
  });

  /// What the assistant called it — the handle `serve.py stop` takes.
  final String name;
  final String command;
  final String directory;
  final DateTime? startedAt;

  /// The port it was started to answer on, when it was given one. Null means the
  /// app cannot check whether it is up, and must not claim it is.
  final int? port;

  final String? logPath;

  /// Where to point a browser. Null without a port — there is nothing to open.
  String? get url => port == null ? null : 'http://localhost:$port';

  /// One record as `serve.py` writes it, or null when the file is not one.
  ///
  /// Lenient on everything except the name: a record with no name can't be
  /// stopped, so a row for it would be a button that does nothing.
  static ServedService? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = '${raw['name'] ?? ''}'.trim();
    if (name.isEmpty) return null;
    final port = raw['port'];
    return ServedService(
      name: name,
      command: '${raw['cmd'] ?? ''}',
      directory: '${raw['dir'] ?? ''}',
      startedAt: DateTime.tryParse('${raw['started_at']}'),
      port: port is int ? port : int.tryParse('$port'),
      logPath: raw['log'] is String ? raw['log'] as String : null,
    );
  }
}

/// Reads the records `grid-serve` leaves in `~/.grid/app/services`.
///
/// App-owned but written by the skill's script, so it is read leniently: a
/// half-written file drops one row rather than the list.
class ServedServicesStore {
  ServedServicesStore({Directory? directory})
    : _dir = directory ?? GridPaths.servicesDir;

  final Directory _dir;

  /// The one record for [name] — `serve.py` names the file after the service.
  File recordFile(String name) => File('${_dir.path}/$name.json');

  /// Drop the record for [name], leaving its log where `logs <name>` finds it.
  ///
  /// The row is drawn from this file, so this is the app's own way out of one.
  /// It exists because the skill's stop is not always able to remove it — an
  /// older `serve.py` rewrote the record instead, and a machine with no `uv`
  /// could not run the script at all — and either way the user was left
  /// clicking Stop on a notice nothing could clear (issue #42).
  Future<void> forget(String name) async {
    final file = recordFile(name);
    if (await file.exists()) await file.delete();
  }

  Future<List<ServedService>> load() async {
    if (!await _dir.exists()) return const [];
    final services = <ServedService>[];
    await for (final entry in _dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final service = ServedService.fromJson(
          jsonDecode(await entry.readAsString()),
        );
        if (service != null) services.add(service);
      } on Object {
        continue;
      }
    }
    services.sort((a, b) => a.name.compareTo(b.name));
    return services;
  }
}

final servedServicesStoreProvider = Provider<ServedServicesStore>(
  (ref) => ServedServicesStore(),
);

/// Whether something is actually answering on [port].
///
/// The only liveness check the app makes, and it is deliberately the honest one:
/// a pid in a record proves a process existed when it was written, and a pid can
/// be recycled. A port that answers is the thing the user cares about anyway.
Future<bool> portAnswers(int port, {Duration timeout = _kProbe}) async {
  try {
    final socket = await Socket.connect('localhost', port, timeout: timeout);
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

const Duration _kProbe = Duration(milliseconds: 300);

/// A service and whether its port answers right now. Null [answering] means
/// there is no port to ask, so the row says when it started and claims nothing.
typedef ServiceStatus = ({ServedService service, bool? answering});

/// What this computer is running, with each port probed once.
///
/// `autoDispose` and read on demand rather than polled: the list changes when
/// the assistant starts or stops something, and the screens that show it ask
/// again when they come back.
final servedServicesProvider = FutureProvider.autoDispose<List<ServiceStatus>>((
  ref,
) async {
  final services = await ref.read(servedServicesStoreProvider).load();
  return [
    for (final service in services)
      (
        service: service,
        answering: service.port == null
            ? null
            : await portAnswers(service.port!),
      ),
  ];
});

/// What a stop attempt actually achieved.
///
/// Three outcomes rather than a bool, because "the stop ran" and "the thing is
/// gone" are different facts and only the second one may take the row away.
enum ServiceStopOutcome {
  /// It was stopped, and its record went with it.
  stopped,

  /// The stop could not run, but nothing answers on the port — so the app
  /// dropped the record itself rather than keep a notice for something that is
  /// provably not there.
  cleared,

  /// It is still up. The row stays, and the user is told where to go.
  stillRunning,
}

/// Stop [service] the way the skill would, and make sure its row cannot outlive
/// it.
///
/// Through `serve.py stop`, not by signalling the pid ourselves: which supervisor
/// holds the process — launchd, screen, tmux, or nothing — is recorded by the
/// script, and killing a launchd job's pid leaves launchd to restart it. Copying
/// that logic into Dart would be a second implementation to keep in step.
///
/// Then the **record**, not the exit code, decides what the user sees: that file
/// is what the row is made of, and the script is not always able to remove it.
/// An older `serve.py` rewrote it; a machine with no `uv` could not run the
/// script at all. Both left a Stop button that looked like it did nothing, which
/// is what a user reported twice (issue #42). So a stop that ran takes the
/// record with it, and a stop that could not run still clears a service whose
/// port is provably silent.
///
/// What keeps that honest is [ServiceStopOutcome.stillRunning]: a service that
/// still answers keeps its row, and so does one with no port — its record is the
/// only handle anything has on a process that may well be alive, and dropping it
/// would strand the process instead of stopping it.
Future<ServiceStopOutcome> stopServedService(
  ServedService service, {
  String? home,
  ServedServicesStore? store,
  AppLog? log,
  Future<bool> Function(int port)? probePort,
}) async {
  final records = store ?? ServedServicesStore();
  final run = await _runStopScript(service.name, home: home, log: log);
  if (run == _StopRun.refused) return ServiceStopOutcome.stillRunning;
  if (run == _StopRun.ok) {
    await records.forget(service.name);
    return ServiceStopOutcome.stopped;
  }
  final port = service.port;
  if (port == null || await (probePort ?? portAnswers)(port)) {
    return ServiceStopOutcome.stillRunning;
  }
  await records.forget(service.name);
  return ServiceStopOutcome.cleared;
}

/// What the script itself reported: it stopped the service, it refused because
/// the service is still up, or it never got to say.
enum _StopRun { ok, refused, unavailable }

/// Run `serve.py stop <name>` and read what it said.
///
/// Every failure is logged raw as well as answered: a stop that quietly does
/// nothing is exactly the bug this row keeps hitting, and a log that only
/// repeats the sentence the user read diagnoses none of it (§6).
Future<_StopRun> _runStopScript(
  String name, {
  required String? home,
  required AppLog? log,
}) async {
  final script = _serveScript(home);
  if (script == null) {
    log?.warn('agent', 'stop $name: the grid-serve skill is not installed');
    return _StopRun.unavailable;
  }
  final stop = _stopCommand(script, name);
  if (stop == null) {
    log?.warn('agent', 'stop $name: no uv and no python3 to run serve.py');
    return _StopRun.unavailable;
  }
  try {
    final result = await Process.run(stop.executable, stop.arguments);
    if (result.exitCode == 0) return _StopRun.ok;
    if (result.exitCode == kServeStillRunningExit) return _StopRun.refused;
    // The humanised line the user reads diagnoses nothing on its own (§6).
    log?.warn(
      'agent',
      'serve.py stop $name exited ${result.exitCode}: ${result.stderr}',
    );
    return _StopRun.unavailable;
  } on ProcessException catch (error) {
    log?.failure('agent', 'serve.py stop $name could not run', error: error);
    return _StopRun.unavailable;
  }
}

/// How to run `serve.py`: the pinned `uv` when it is really there, else any
/// `python3` this machine has.
///
/// Null when it has neither. The script is stdlib-only and `uv` is not: the
/// pinned copy arrives with Hermes, so on a Codex- or Claude-only machine
/// [gridSkillUvPath] names a file that does not exist — every stop would throw
/// on it, and the row would be one nothing could ever clear.
({String executable, List<String> arguments})? _stopCommand(
  String script,
  String name,
) {
  final uv = gridSkillUvPath();
  if (File(uv).existsSync()) {
    return (
      executable: uv,
      arguments: ['run', '--no-project', 'python3', script, 'stop', name],
    );
  }
  final python = HostEnvironment.findExecutable('python3');
  if (python == null) return null;
  return (executable: python, arguments: [script, 'stop', name]);
}

/// The `serve.py` from the app's own library copy of the skill — the same file
/// the agents run. Null when no agent's library folder holds it.
String? _serveScript(String? home) {
  for (final agent in AgentTool.values) {
    final dir = AgentSkillHome(
      agent,
      home: home,
    ).libraryGridDir(kGridServeSkillName);
    final script = File('${dir.path}/scripts/serve.py');
    if (script.existsSync()) return script.path;
  }
  return null;
}
