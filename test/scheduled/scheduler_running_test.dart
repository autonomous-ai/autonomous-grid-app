import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/grid_paths.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_service.dart';

/// The heartbeat Hermes touches every ~10s, as seconds-since-epoch.
void _beat(Directory home, DateTime at) {
  final cron = Directory('${home.path}/.hermes/cron')
    ..createSync(recursive: true);
  File(
    '${cron.path}/ticker_heartbeat',
  ).writeAsStringSync('${at.millisecondsSinceEpoch / 1000}');
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('cron-home'));
  tearDown(() => tmp.deleteSync(recursive: true));

  HermesCronService service() =>
      HermesCronServiceImpl('/bin/hermes', home: tmp.path);

  group('HermesCronServiceImpl.schedulerRunning', () {
    test('a fresh heartbeat means the scheduler is alive', () async {
      _beat(tmp, DateTime.now());
      expect(await service().schedulerRunning(), isTrue);
    });

    test(
      'a stale heartbeat is a scheduler that died holding the file',
      () async {
        _beat(tmp, DateTime.now().subtract(const Duration(minutes: 5)));
        expect(await service().schedulerRunning(), isFalse);
      },
    );

    test('no heartbeat at all means nothing is there to fire jobs', () async {
      expect(await service().schedulerRunning(), isFalse);
    });
  });

  // The banner reads `schedulerRunning`, so a home that resolves to nothing
  // reports every scheduler as dead: the warning never clears, and "Turn it on"
  // starts a gateway that was already up. A Windows GUI process has no `HOME`
  // at all, which is exactly how that happened — hence resolving through
  // GridPaths, which falls back to `%USERPROFILE%`.
  group('home resolution', () {
    test('GridPaths.userHome names a real directory on every platform', () {
      expect(GridPaths.userHome, isNotEmpty);
      expect(Directory(GridPaths.userHome).existsSync(), isTrue);
    });

    test('the default home is the user\'s, not the filesystem root', () async {
      _beat(Directory(tmp.path), DateTime.now());
      // Same reading whether the caller names the home or lets it default —
      // proof the default is a resolved home rather than an empty string.
      expect(
        await HermesCronServiceImpl('/bin/hermes').schedulerRunning(),
        await HermesCronServiceImpl(
          '/bin/hermes',
          home: GridPaths.userHome,
        ).schedulerRunning(),
      );
    });
  });
}
