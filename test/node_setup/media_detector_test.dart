import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

const _installedOutput = '''
Installed       : yes (/Users/x/.grid/comfyui)
Python (venv)   : /Users/x/.grid/comfyui/venv/bin/python
Output dir      : /Users/x/.grid/outputs
Bundle image_generation   3/3 files present
Bundle image_editing      0/2 files present
Bundle i2v                0/4 files present
Running         : no (port 8188)
''';

void main() {
  test('parses installed status, running flag, and bundle presence', () {
    final status = MediaDetector.parseStatus(_installedOutput);

    expect(status.installed, isTrue);
    expect(status.running, isFalse);

    final imageGen = status.bundle('image_generation')!;
    expect(imageGen.filesPresent, 3);
    expect(imageGen.filesTotal, 3);
    expect(imageGen.isComplete, isTrue);
    expect(status.bundle('image_editing')!.isComplete, isFalse);
  });

  test('parses a not-installed status', () {
    final status = MediaDetector.parseStatus(
      'Installed       : no (/Users/x/.grid/comfyui)\n'
      'Running         : no (port 8188)\n',
    );
    expect(status.installed, isFalse);
    expect(status.running, isFalse);
    expect(status.bundles, isEmpty);
  });

  test('detect() reports not-installed when the CLI command fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(['engine', 'status'],
          const CliResult(exitCode: 2, stdout: '', stderr: 'media unsupported'));

    final status = await MediaDetector(fake).detect();
    expect(status.installed, isFalse);
  });

  test('detect() reports not-installed when grid is absent', () async {
    expect((await const MediaDetector(null).detect()).installed, isFalse);
  });
}
