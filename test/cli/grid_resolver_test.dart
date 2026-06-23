import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/grid_resolver.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('grid_resolver'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  File makeExecutable(String name) {
    final file = File('${tempDir.path}/$name')
      ..writeAsStringSync('#!/bin/sh\necho ok\n');
    Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  test('a configured executable path wins, even over PATH', () {
    final bin = makeExecutable('grid');
    final resolver = GridResolver(
      configuredPath: bin.path,
      pathLookup: () => '/usr/bin/grid',
    );
    expect(resolver.resolve(), bin.absolute.path);
  });

  test('falls back to PATH when nothing is configured or bundled', () {
    final onPath = makeExecutable('grid_on_path');
    final resolver = GridResolver(pathLookup: () => onPath.path);
    expect(resolver.resolve(), onPath.absolute.path);
  });

  test('returns null when nothing resolves', () {
    final resolver = GridResolver(
      configuredPath: '${tempDir.path}/does-not-exist',
      pathLookup: () => null,
    );
    expect(resolver.resolve(), isNull);
  });

  test('ignores a non-executable file', () {
    final notExec = File('${tempDir.path}/grid')..writeAsStringSync('x');
    final resolver =
        GridResolver(configuredPath: notExec.path, pathLookup: () => null);
    expect(resolver.resolve(), isNull);
  });
}
