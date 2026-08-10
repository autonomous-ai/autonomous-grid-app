import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/host_arch.dart';
import 'package:grid_app/infrastructure/cli/agent_download.dart';
import 'package:grid_app/infrastructure/cli/agent_release_pins.dart';
import 'package:grid_app/infrastructure/cli/agent_spec_installer.dart';

/// Every desktop platform the app claims to run agents on. If a pin is missing
/// for one of these, install fails at runtime on that machine — so the coverage
/// test below is the guard that a version bump didn't drop a platform.
const _desktopAbis = [
  Abi.macosArm64,
  Abi.macosX64,
  Abi.windowsArm64,
  Abi.windowsX64,
  Abi.linuxX64,
  Abi.linuxArm64,
];

void main() {
  group('uvToolInstallArgs', () {
    test('installs the requirement with --force on a pinned Python', () {
      // A wrong flag fails exactly like a package that wouldn't build, so the
      // argv is pinned here rather than trusted by eye.
      expect(
        uvToolInstallArgs(package: 'hermes-agent[acp,mcp]', python: '3.13'),
        [
          'tool',
          'install',
          '--force',
          '--python',
          '3.13',
          'hermes-agent[acp,mcp]',
        ],
      );
    });
  });

  group('release pins cover every desktop platform', () {
    test('uv has a hash-verified build for each', () {
      for (final abi in _desktopAbis) {
        final target = agentPlatformTarget(abi, linuxMusl: false)!;
        final build = uvBuildFor(target);
        expect(build, isNotNull, reason: 'no uv build for $target');
        expect(build!.url, contains(kUvRelease));
        expect(build.sha256, hasLength(64));
      }
    });

    test('Codex has a hash-verified build for each (Linux is musl)', () {
      for (final abi in _desktopAbis) {
        final target = agentPlatformTarget(abi, linuxMusl: true)!;
        final build = codexBuildFor(target);
        expect(build, isNotNull, reason: 'no Codex build for $target');
        expect(build!.url, contains(kCodexRelease));
        expect(build.sha256, hasLength(64));
      }
    });

    test('Node has a hash-verified build for each (Pi runs on it)', () {
      for (final abi in _desktopAbis) {
        // Pi's Node is the gnu Linux build, so it resolves with linuxMusl false
        // just like uv.
        final target = agentPlatformTarget(abi, linuxMusl: false)!;
        final build = nodeBuildFor(target);
        expect(build, isNotNull, reason: 'no Node build for $target');
        expect(build!.url, contains(kNodeRelease));
        expect(build.sha256, hasLength(64));
      }
    });

    test('an unpinned target resolves to nothing, not a bad guess', () {
      expect(uvBuildFor('sparc-sun-solaris'), isNull);
      expect(codexBuildFor('sparc-sun-solaris'), isNull);
      expect(nodeBuildFor('sparc-sun-solaris'), isNull);
    });
  });

  group('verifySha256 — the wall between a download and running it', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid-sha-test-');
    });
    tearDown(() async => tmp.delete(recursive: true));

    test('passes when the file matches its pinned hash', () async {
      final file = File('${tmp.path}/blob');
      await file.writeAsString('grid agent payload');
      final digest = sha256.convert(await file.readAsBytes()).toString();

      await expectLater(verifySha256(file, digest), completes);
    });

    test('throws when it does not — a tampered or truncated archive never '
        'reaches the machine', () async {
      final file = File('${tmp.path}/blob');
      await file.writeAsString('grid agent payload');

      await expectLater(
        verifySha256(file, 'f' * 64),
        throwsA(isA<AgentDownloadException>()),
      );
    });
  });
}
