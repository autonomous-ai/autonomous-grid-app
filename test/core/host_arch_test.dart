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
}
