import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/host_arch.dart';

void main() {
  group('isAppleSiliconAbi', () {
    test('true only for an Apple Silicon (arm64) Mac', () {
      expect(isAppleSiliconAbi(Abi.macosArm64), isTrue);
    });

    test('false for an Intel Mac', () {
      expect(isAppleSiliconAbi(Abi.macosX64), isFalse);
    });

    test('false for Linux and Windows on every arch', () {
      expect(isAppleSiliconAbi(Abi.linuxX64), isFalse);
      expect(isAppleSiliconAbi(Abi.linuxArm64), isFalse);
      expect(isAppleSiliconAbi(Abi.windowsX64), isFalse);
      expect(isAppleSiliconAbi(Abi.windowsArm64), isFalse);
    });
  });
}
