import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';

const _home = '/home/u';

ClientAppDetector _detector({
  Set<String> dirs = const {},
  Set<String> executables = const {},
}) =>
    ClientAppDetector(
      home: _home,
      dirExists: dirs.contains,
      findExecutable: (name) => executables.contains(name) ? '/bin/$name' : null,
    );

void main() {
  test('a present config directory marks the app installed', () {
    final d = _detector(dirs: {'$_home/.openclaw'});
    expect(d.isInstalled(ClientApp.openClaw), isTrue);
    expect(d.isInstalled(ClientApp.hermes), isFalse);
    expect(d.detect(), {ClientApp.openClaw});
  });

  test('an executable on PATH counts even without a config dir', () {
    final d = _detector(executables: {'hermes'});
    expect(d.isInstalled(ClientApp.hermes), isTrue);
    expect(d.detect(), {ClientApp.hermes});
  });

  test('neither signal means not installed', () {
    expect(_detector().detect(), isEmpty);
  });

  test('detect() returns apps in ClientApp.values order', () {
    final d = _detector(
      dirs: {'$_home/.openclaw', '$_home/.hermes'},
    );
    expect(d.detect().toList(), ClientApp.values);
  });
}
