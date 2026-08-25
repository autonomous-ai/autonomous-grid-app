import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/panel/panel_frame.dart';
import 'package:grid_app/infrastructure/panel/panel_link.dart';
import 'package:grid_app/infrastructure/panel/panel_message.dart';

/// A transport backed by two lists instead of a cable.
///
/// The whole reason [PanelLink] takes an interface: the protocol is exercised
/// end to end here, and against a real device by tool/panel_tap.dart, without
/// either one needing the other.
class _FakeTransport implements PanelTransport {
  final _in = StreamController<List<int>>();
  final sent = <List<int>>[];
  var closed = false;

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
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  /// Deliver bytes as if the driver had just returned them.
  void deliver(List<int> bytes) => _in.add(bytes);
}

void main() {
  group('parsing what the panel says', () {
    test('hello carries the firmware, protocol and MAC', () {
      final msg = PanelInbound.parse(
        '{"t":"hello","product":"grid","fw":"0.1.0","proto":7,"mac":"A4:CB:8F:CF:D0:78"}',
      );
      expect(msg, isA<PanelHello>());
      final hello = msg as PanelHello;
      expect(hello.firmware, '0.1.0');
      expect(hello.mac, 'A4:CB:8F:CF:D0:78');
      expect(hello.isCompatible, isTrue);
    });

    test(
      'a firmware on another protocol reads as incompatible, not broken',
      () {
        // The app carries the firmware image and can offer to fix this, so a
        // mismatch has to arrive as a state rather than as a parse failure.
        final hello =
            PanelInbound.parse('{"t":"hello","product":"grid","fw":"9.0.0","proto":99,"mac":""}')
                as PanelHello;
        expect(hello.isCompatible, isFalse);
        expect(hello.protocol, 99);
      },
    );

    test('stop names its project, so any of them can be stopped', () {
      // The panel can stop a turn in a project the desktop does not have open,
      // which is the whole reason the id travels.
      final msg =
          PanelInbound.parse('{"t":"turn.stop","chatId":"c-7"}')
              as PanelStopRequested;
      expect(msg.chatId, 'c-7');
    });

    test('an unknown message is kept, so newer firmware is visible', () {
      final msg =
          PanelInbound.parse('{"t":"screen.brightness","level":40}')
              as PanelUnknown;
      expect(msg.type, 'screen.brightness');
      expect(msg.payload['level'], 40);
    });

    test(
      'junk is reported rather than thrown, because it came off a cable',
      () {
        // Anything that arrives here is untrusted. Throwing would take down the
        // link that delivered it, which is the opposite of what a bad byte
        // deserves.
        expect(PanelInbound.parse('not json at all'), isA<PanelMalformed>());
        expect(PanelInbound.parse('[1,2,3]'), isA<PanelMalformed>());
        expect(PanelInbound.parse('{"no":"type"}'), isA<PanelMalformed>());
      },
    );

    test('a missing field falls back instead of failing the message', () {
      final hello = PanelInbound.parse('{"t":"hello"}') as PanelHello;
      expect(hello.firmware, '');
      expect(hello.protocol, 0);
      expect(hello.isCompatible, isFalse);
    });
  });

  group('the link over a transport', () {
    test('bytes in become typed messages out', () async {
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final received = <PanelInbound>[];
      link.messages.listen(received.add);

      transport.deliver(encodePanelJson('{"t":"chats.list"}'));
      await pumpEventQueue();

      expect(received.single, isA<PanelChatsRequested>());
    });

    test('PCM is kept off the message stream', () async {
      // Audio is a different shape of traffic — high rate, no meaning per
      // chunk — and folding it in would make every listener filter it out.
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final messages = <PanelInbound>[];
      final audio = <List<int>>[];
      link.messages.listen(messages.add);
      link.audio.listen(audio.add);

      transport.deliver(encodePanelFrame(PanelFrameType.pcm, [1, 2, 3, 4]));
      await pumpEventQueue();

      expect(messages, isEmpty);
      expect(audio.single, [1, 2, 3, 4]);
    });

    test('boot noise is absorbed and the first real message survives', () async {
      // Every boot, the ROM and bootloader leave bytes on this port before the
      // firmware owns it. The link has to start mid-stream and still work.
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final received = <PanelInbound>[];
      link.messages.listen(received.add);

      transport.deliver(utf8.encode('ESP-ROM:esp32s3\r\nrst:0x1\r\n'));
      transport.deliver(encodePanelJson('{"t":"hello","product":"grid","proto":7}'));
      await pumpEventQueue();

      expect(received.single, isA<PanelHello>());
      expect(link.discardedBytes, greaterThan(0));
      expect(link.corruptFrames, 0);
    });

    test('a frame type this build predates is counted, not dropped', () async {
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final received = <PanelInbound>[];
      link.messages.listen(received.add);

      final frame = encodePanelFrame(PanelFrameType.pcm, [9]).toList();
      frame[3] = 0x7F;
      final crc = panelCrc16(frame, start: 2, end: kPanelHeaderBytes + 1);
      frame[frame.length - 2] = crc & 0xFF;
      frame[frame.length - 1] = (crc >> 8) & 0xFF;
      transport.deliver(frame);
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(link.unknownFrames, 1);
    });

    test('sending wraps the JSON in a frame the decoder can read back', () {
      final transport = _FakeTransport();
      PanelLink(transport).send(PanelOutbound.turnStarted('c-1'));

      final decoded = PanelFrameDecoder().feed(transport.sent.single).single;
      expect(decoded.type, PanelFrameType.json);
      expect(jsonDecode(decoded.text), {'t': 'turn.started', 'chatId': 'c-1'});
    });

    test('a project tile carries only what a tile draws', () {
      // Deliberately thin: the panel draws a name, a state and a line of
      // recap. Instructions, memory and the workspace path stay in the app.
      final json =
          jsonDecode(
                PanelOutbound.chats([
                  const PanelChat(
                    id: 'p-1',
                    name: 'grid-app',
                    agent: 'claude',
                    busy: true,
                    recap: 'Ran the tests',
                  ),
                ]),
              )
              as Map<String, Object?>;

      final item = (json['items']! as List).single as Map<String, Object?>;
      expect(item['id'], 'p-1');
      expect(item['busy'], true);
      expect(item['recap'], 'Ran the tests');
      expect(item.containsKey('model'), isFalse); // absent, not null
    });

    test('a greeting from another product is not forwarded, and the port is '
        'let go — there is no session to have with somebody else\'s device', () async {
      // The board is shared: Grid Panel and the Harness dial are the same
      // Waveshare 466x466 ESP32-S3 and enumerate with the same USB id, so this
      // app can and did open a dial's port. Answering it with a `welcome` is
      // what let it then write Grid firmware into someone's dial.
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final received = <PanelInbound>[];
      link.messages.listen(received.add);

      transport.deliver(
        encodePanelJson('{"t":"hello","product":"harness","fw":"0.0.39"}'),
      );
      await pumpEventQueue();

      expect(received, isEmpty, reason: 'the controller must never see it');
      expect(transport.sent, isEmpty, reason: 'not even a refusal');
      expect(transport.disowned.single, contains('another product'));
    });

    test('a greeting with no product at all is treated as foreign, because '
        'the firmware that predates the field is the capturable one', () async {
      // ABSENCE MEANS NO. Reading a missing `product` as "probably mine" would
      // put the whole hole back exactly where it is deepest: every board
      // flashed before 2026-08-25 omits it, and those are the boards either
      // product can still take. Such a panel is recovered by flashing it over
      // USB by hand, once.
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      final received = <PanelInbound>[];
      link.messages.listen(received.add);

      transport.deliver(encodePanelJson('{"t":"hello","fw":"0.1.27"}'));
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(transport.disowned, hasLength(1));
    });

    test('closing releases the transport and forgets any half-frame', () async {
      final transport = _FakeTransport();
      final link = PanelLink(transport);
      transport.deliver(encodePanelJson('{"t":"hello"}').sublist(0, 4));
      await pumpEventQueue();

      await link.close();
      expect(transport.closed, isTrue);
    });
  });
}
