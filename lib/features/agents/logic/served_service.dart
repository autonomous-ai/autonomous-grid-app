import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
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

/// Stop [name] the way the skill would.
///
/// Through `serve.py stop`, not by signalling the pid ourselves: which supervisor
/// holds the process — launchd, screen, tmux, or nothing — is recorded by the
/// script, and killing a launchd job's pid leaves launchd to restart it. Copying
/// that logic into Dart would be a second implementation to keep in step.
///
/// Returns whether the stop ran. False when the skill isn't installed anywhere
/// the app can find, which the caller must say rather than pretending it worked.
Future<bool> stopServedService(String name, {String? home}) async {
  final script = _serveScript(home);
  if (script == null) return false;
  try {
    final result = await Process.run(gridSkillUvPath(), [
      'run',
      '--no-project',
      'python3',
      script,
      'stop',
      name,
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
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
