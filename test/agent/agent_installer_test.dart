import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/host_arch.dart';
import 'package:grid_app/infrastructure/cli/agent_download.dart';
import 'package:grid_app/infrastructure/cli/agent_installer.dart';
import 'package:grid_app/infrastructure/cli/agent_release_pins.dart';

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
      expect(uvToolInstallArgs(package: 'hermes-agent[acp]', python: '3.13'), [
        'tool',
        'install',
        '--force',
        '--python',
        '3.13',
        'hermes-agent[acp]',
      ]);
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

    test('an unpinned target resolves to nothing, not a bad guess', () {
      expect(uvBuildFor('sparc-sun-solaris'), isNull);
      expect(codexBuildFor('sparc-sun-solaris'), isNull);
    });
  });

  group('a command-installed agent with its tool missing', () {
    test('is an honest dead end naming the tool, not a retryable spawn error — '
        'no npm on the machine is not "check your connection"', () async {
      // A bogus tool name never resolves on any PATH, so this is the "user has
      // no npm/node" case: install must say what to install, and must not be
      // retryable, because no retry conjures a missing runtime.
      const spec = CommandInstall(['grid-no-such-tool-xyz', 'i', '-g', 'x']);
      await expectLater(
        const AgentInstallerImpl().run(spec),
        throwsA(
          isA<AgentInstallException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having(
                (e) => e.message,
                'message',
                contains('grid-no-such-tool-xyz'),
              ),
        ),
      );
    });
  });

  group('verifySha256', () {
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

    test(
      'throws when the hash does not match — the wall before running it',
      () async {
        final file = File('${tmp.path}/blob');
        await file.writeAsString('grid agent payload');
        await expectLater(
          verifySha256(file, 'f' * 64),
          throwsA(isA<AgentDownloadException>()),
        );
      },
    );
  });
}
