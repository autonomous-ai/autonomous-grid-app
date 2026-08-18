import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/served_service.dart';
import 'package:grid_app/features/agents/presentation/running_service_notes.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_services_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  File record(String name, String json) =>
      File('${tmp.path}/$name.json')..writeAsStringSync(json);

  ServedService service({int? port}) => ServedService(
    name: 'web',
    command: 'npm run dev',
    directory: '/tmp',
    startedAt: DateTime(2026, 8, 5),
    port: port,
  );

  group('reading what grid-serve left behind', () {
    test('a record becomes a row with somewhere to open', () async {
      record('web', '''
{"name": "web", "cmd": "npm run dev", "dir": "/tmp/app", "port": 3000,
 "started_at": "2026-08-05T09:00:00", "log": "/tmp/web.log"}
''');

      final services = await ServedServicesStore(directory: tmp).load();
      expect(services.single.name, 'web');
      expect(services.single.port, 3000);
      expect(services.single.url, 'http://localhost:3000');
      expect(services.single.command, 'npm run dev');
    });

    test('a record with no name is dropped — the row would be a Stop button '
        'with nothing to stop', () async {
      record('broken', '{"port": 3000}');
      expect(await ServedServicesStore(directory: tmp).load(), isEmpty);
    });

    test('an unreadable file costs its own row, not the list', () async {
      record('good', '{"name": "good"}');
      record('bad', 'half a json {');
      final services = await ServedServicesStore(directory: tmp).load();
      expect([for (final s in services) s.name], ['good']);
    });

    test('a missing folder is simply nothing running', () async {
      final gone = Directory('${tmp.path}/nope');
      expect(await ServedServicesStore(directory: gone).load(), isEmpty);
    });

    test('no port means nothing to open — the app must not invent a URL', () {
      final service = ServedService.fromJson({'name': 'worker'});
      expect(service?.port, isNull);
      expect(service?.url, isNull);
    });
  });

  group('a row the user can always get out of', () {
    // No skill folder under this home, so the stop script is nowhere to be
    // found — the same dead end as a machine with no `uv`, and offline.
    Future<ServiceStopOutcome> stop(
      ServedService service, {
      required bool answering,
    }) => stopServedService(
      service,
      home: tmp.path,
      store: ServedServicesStore(directory: tmp),
      probePort: (_) async => answering,
    );

    test('a stop that cannot run still clears a service nothing is answering '
        'for — the user clicked Stop three times on a notice no click could '
        'remove (#42)', () async {
      record('web', '{"name": "web", "port": 3100}');
      final log = File('${tmp.path}/web.log')..writeAsStringSync('boot');

      final outcome = await stop(service(port: 3100), answering: false);

      expect(outcome, ServiceStopOutcome.cleared);
      expect(File('${tmp.path}/web.json').existsSync(), isFalse);
      // The log outlives the record, so `logs web` still explains what died.
      expect(log.existsSync(), isTrue);
    });

    test('a service that is still answering keeps its row — clearing one that '
        'is alive would hide it instead of stopping it', () async {
      record('web', '{"name": "web", "port": 3100}');

      final outcome = await stop(service(port: 3100), answering: true);

      expect(outcome, ServiceStopOutcome.stillRunning);
      expect(File('${tmp.path}/web.json').existsSync(), isTrue);
    });

    test('with no port there is no evidence, so the record stays: it is the '
        'only handle anything has left on the process', () async {
      record('worker', '{"name": "worker"}');

      final outcome = await stop(service(), answering: false);

      expect(outcome, ServiceStopOutcome.stillRunning);
      expect(File('${tmp.path}/worker.json').existsSync(), isTrue);
    });

    test('forgetting a service drops its record and nothing else', () async {
      record('web', '{"name": "web"}');
      final log = File('${tmp.path}/web.log')..writeAsStringSync('boot');

      await ServedServicesStore(directory: tmp).forget('web');

      expect(File('${tmp.path}/web.json').existsSync(), isFalse);
      expect(log.existsSync(), isTrue);
      expect(await ServedServicesStore(directory: tmp).load(), isEmpty);
    });

    test('a failed stop says where the thing still is, not just that the click '
        'failed', () {
      final message = stopFailedMessage(service(port: 3100));

      expect(message, contains('port 3100'));
      expect(message, contains('terminal'));
    });
  });

  group('what the row claims', () {
    test('only a port that answers is called running', () {
      expect(
        serviceLabel((service: service(port: 3000), answering: true)),
        'web is running on port 3000',
      );
    });

    test('a port that stopped answering says so instead of staying green — a '
        'row that lies about a dead server is worse than no row', () {
      expect(
        serviceLabel((service: service(port: 3000), answering: false)),
        contains('nothing is answering'),
      );
    });

    test('with no port to ask, the row claims nothing it cannot check', () {
      final label = serviceLabel((service: service(), answering: null));
      expect(label, 'web was started on this computer');
      expect(label, isNot(contains('running')));
    });
  });
}
