import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/host_arch.dart';

void main() {
  group('isMacAbi', () {
    test('true for an Apple Silicon Mac', () {
      expect(isMacAbi(Abi.macosArm64), isTrue);
    });

    test('true for an Intel Mac — it has an official llama.cpp build too', () {
      expect(isMacAbi(Abi.macosX64), isTrue);
    });

    test('false for Linux and Windows on every arch', () {
      expect(isMacAbi(Abi.linuxX64), isFalse);
      expect(isMacAbi(Abi.linuxArm64), isFalse);
      expect(isMacAbi(Abi.windowsX64), isFalse);
      expect(isMacAbi(Abi.windowsArm64), isFalse);
    });
  });

  group('agentPlatformTarget', () {
    test('maps each supported ABI to its release-artifact triple', () {
      String target(Abi abi) => agentPlatformTarget(abi, linuxMusl: false)!;
      expect(target(Abi.macosArm64), 'aarch64-apple-darwin');
      expect(target(Abi.macosX64), 'x86_64-apple-darwin');
      expect(target(Abi.windowsArm64), 'aarch64-pc-windows-msvc');
      expect(target(Abi.windowsX64), 'x86_64-pc-windows-msvc');
    });

    test('picks the Linux libc — Codex is static musl, uv is gnu', () {
      expect(
        agentPlatformTarget(Abi.linuxX64, linuxMusl: true),
        'x86_64-unknown-linux-musl',
      );
      expect(
        agentPlatformTarget(Abi.linuxX64, linuxMusl: false),
        'x86_64-unknown-linux-gnu',
      );
      expect(
        agentPlatformTarget(Abi.linuxArm64, linuxMusl: true),
        'aarch64-unknown-linux-musl',
      );
    });

    test('an unknown platform has no target rather than a wrong guess', () {
      expect(agentPlatformTarget(Abi.androidArm64, linuxMusl: false), isNull);
    });
  });
}
