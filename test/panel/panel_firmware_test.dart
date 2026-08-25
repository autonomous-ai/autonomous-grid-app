import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/panel/logic/panel_firmware_updater.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';
import 'package:grid_app/infrastructure/panel/panel_firmware.dart';
import 'package:grid_app/infrastructure/panel/panel_frame.dart';
import 'package:grid_app/infrastructure/panel/panel_link.dart';

/// An ESP-IDF application image, as far as anything in this app reads one: the
/// image magic, then the `esp_app_desc_t` the version is taken out of.
///
/// Built rather than checked in, so the tests do not depend on a firmware build
/// having happened on this machine — and public so the controller tests can
/// hand the same thing to the offer path.
Uint8List espAppImage({required String version, int size = 20000}) {
  final image = Uint8List(size < 128 ? 128 : size);
  image[0] = 0xE9;
  ByteData.sublistView(image).setUint32(32, 0xABCD5432, Endian.little);
  image.setRange(48, 48 + version.length, version.codeUnits);
  // A pattern, so a slice that arrives out of order is visible as one.
  for (var i = 128; i < image.length; i++) {
    image[i] = i % 251;
  }
  return image;
}

/// A transport backed by two lists instead of a cable — the same fake
/// `panel_link_test.dart` drives the framing with, so the updater is exercised
/// over the real codec and never over a stub of it.
class _FakeTransport implements PanelTransport {
  final _in = StreamController<List<int>>();
  final sent = <List<int>>[];

  @override
  Stream<List<int>> get incoming => _in.stream;

  @override
  void send(List<int> bytes) => sent.add(bytes);

  /// Ports let go because the device on them belongs to another product, with
  /// the reason the link gave. Recorded rather than ignored: "the link let the
  /// port go" and "the link said nothing" look identical from the outside, and
  /// telling them apart is the whole point of the tests that use this.
  final disowned = <String>[];

  @override
  void disown(String why) => disowned.add(why);

  @override
  Future<void> close() => _in.close();

  /// Everything the app has said, decoded back through the real framing.
  List<PanelFrame> get frames {
    final decoder = PanelFrameDecoder();
    return [for (final chunk in sent) ...decoder.feed(chunk)];
  }

  /// Just the firmware payloads, in the order they went out.
  List<Uint8List> get imageFrames => [
    for (final frame in frames)
      if (frame.type == PanelFrameType.firmware) frame.payload,
  ];

  Map<String, Object?> get firstMessage =>
      jsonDecode(frames.firstWhere((f) => f.type == PanelFrameType.json).text)
          as Map<String, Object?>;
}

/// A log that keeps what it was told, so a test can assert that a failure was
/// recorded and not only humanised.
class _RecordedLog implements AppLog {
  final lines = <String>[];

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => lines.add('${level.name} $message');
}

void main() {
  group('the image this build carries', () {
    test('states its own version, so nothing recorded beside the bytes can '
        'disagree with them', () {
      // A const, a pubspec line or a sidecar file are all edited separately
      // from the binary, and a version that names bytes it is not reads as
      // "the panel keeps re-offering the same update" — or worse, as an
      // update that is silently never offered.
      final image = PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!;
      expect(image.version, 'v0.4.1');
      expect(image.size, 20000);
    });

    test('carries the sha256 of the whole image, which is what the device '
        'checks against what it actually wrote', () {
      final bytes = espAppImage(version: 'v1');
      final image = PanelFirmwareImage.read(bytes)!;
      expect(image.sha256, crypto.sha256.convert(bytes).toString());
    });

    test('anything that is not an ESP-IDF image is not offered at all', () {
      // A truncated copy, a placeholder, a build that never finished. An image
      // the app cannot read the version of is not one to flash a device with.
      expect(PanelFirmwareImage.read(Uint8List(4096)), isNull);
      expect(PanelFirmwareImage.read(Uint8List.fromList([0xE9, 1, 2])), isNull);
      expect(esp32ImageVersion(espAppImage(version: '')), isNull);
    });
  });

  group('cutting the image up for the cable', () {
    test('every slice fits a frame, and together they are the image byte for '
        'byte — the device writes them straight to flash in order', () {
      final image = espAppImage(version: 'v1', size: 8192 * 3 + 17);
      final slices = panelFirmwareSlices(image);

      expect(slices, hasLength(4));
      expect(slices.every((s) => s.length <= kPanelMaxPayload), isTrue);
      expect(slices.last.length, 17);
      expect([for (final slice in slices) ...slice], image);
    });

    test('a slice size no frame could carry is refused where the bug is, not '
        'one frame into a transfer', () {
      expect(
        () => panelFirmwareSlices(Uint8List(10), limit: kPanelMaxPayload + 1),
        throwsArgumentError,
      );
    });
  });

  group('handing the image to a panel', () {
    late _FakeTransport transport;
    late _RecordedLog log;

    PanelFirmwareUpdater updaterWith({int window = 8192}) =>
        PanelFirmwareUpdater(
          link: PanelLink(transport),
          log: log,
          windowBytes: window,
        );

    setUp(() {
      transport = _FakeTransport();
      log = _RecordedLog();
    });

    test('the offer says which version, how big and what it should hash to — '
        'and nothing follows it until the panel accepts', () async {
      // The panel decides when it is willing: an update must never begin in the
      // middle of a turn someone is watching.
      final image = PanelFirmwareImage.read(espAppImage(version: 'v2'))!;
      expect(updaterWith().offer(image), isTrue);
      await pumpEventQueue();

      expect(transport.firstMessage, {
        't': 'fw.offer',
        'version': 'v2',
        'size': image.size,
        'sha256': image.sha256,
      });
      expect(transport.imageFrames, isEmpty);
    });

    test('accepting starts the image, and the app stops at its window instead '
        'of pushing a megabyte at a device writing flash', () async {
      final updater = updaterWith(window: 8192)
        ..offer(PanelFirmwareImage.read(espAppImage(version: 'v2'))!)
        ..accepted();
      await pumpEventQueue();

      // One frame's worth outstanding, then it waits to be told it landed.
      expect(transport.imageFrames, hasLength(1));
      expect(transport.imageFrames.single.length, kPanelMaxPayload);

      updater.progress(kPanelMaxPayload);
      await pumpEventQueue();
      expect(transport.imageFrames, hasLength(2));
    });

    test(
      'the whole image reaches the panel in order once it keeps up',
      () async {
        final bytes = espAppImage(version: 'v2', size: 8192 * 2 + 5);
        final updater = updaterWith()
          ..offer(PanelFirmwareImage.read(bytes)!)
          ..accepted();
        await pumpEventQueue();

        var written = 0;
        for (var i = 0; i < 5 && written < bytes.length; i++) {
          written = [
            for (final frame in transport.imageFrames) frame.length,
          ].fold(0, (a, b) => a + b);
          updater.progress(written);
          await pumpEventQueue();
        }

        expect([for (final f in transport.imageFrames) ...f], bytes);
        expect(updater.phase, isA<PanelFirmwareSending>());
      },
    );

    test('a second offer while one is outstanding is refused, so the two sides '
        'never disagree about which image the frames belong to', () {
      final updater = updaterWith();
      final image = PanelFirmwareImage.read(espAppImage(version: 'v2'))!;
      expect(updater.offer(image), isTrue);
      expect(updater.offer(image), isFalse);
      expect(updater.phase, isA<PanelFirmwareOffered>());
    });

    test('a panel that reports a failure stops the transfer and frees the link '
        'for the next hello to offer again', () async {
      final updater = updaterWith()
        ..offer(PanelFirmwareImage.read(espAppImage(version: 'v2'))!)
        ..accepted();
      await pumpEventQueue();
      final delivered = transport.imageFrames.length;

      updater.failed('flash write failed at 0x120000');
      updater.progress(kPanelMaxPayload);
      await pumpEventQueue();

      expect(transport.imageFrames, hasLength(delivered));
      expect(updater.phase, isA<PanelFirmwareIdle>());
      expect(updater.busy, isFalse);
      // Humanising is never the only record: the device's own reason is kept.
      expect(log.lines.any((l) => l.contains('flash write failed')), isTrue);
    });

    test('a panel that goes quiet for too long is given up on, rather than '
        'left drawing a progress bar that never moves', () async {
      // Real time, briefly: the stall is a wall-clock guard, and the whole
      // thing it guards against is a clock that keeps running while nothing
      // arrives.
      final updater = PanelFirmwareUpdater(
        link: PanelLink(transport),
        log: log,
        stall: const Duration(milliseconds: 20),
      )..offer(PanelFirmwareImage.read(espAppImage(version: 'v2'))!);
      updater.accepted();

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(updater.busy, isFalse);
      expect(log.lines.any((l) => l.contains('stopped reporting')), isTrue);
      // And the next hello is free to offer again — the way out of a stalled
      // update that does not need the cable pulled.
      expect(
        updater.offer(PanelFirmwareImage.read(espAppImage(version: 'v2'))!),
        isTrue,
      );
    });

    test('an accept for an offer nobody made sends no image — the panel is '
        'answering a version this session never proposed', () async {
      updaterWith().accepted();
      await pumpEventQueue();

      expect(transport.imageFrames, isEmpty);
      expect(log.lines.any((l) => l.startsWith('warn')), isTrue);
    });
  });
}
