import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/served_service.dart';
import 'package:grid_app/features/agents/presentation/running_services_bar.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_services_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  File record(String name, String json) =>
      File('${tmp.path}/$name.json')..writeAsStringSync(json);

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

  group('what the row claims', () {
    ServedService service({int? port}) => ServedService(
      name: 'web',
      command: 'npm run dev',
      directory: '/tmp',
      startedAt: DateTime(2026, 8, 5),
      port: port,
    );

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
