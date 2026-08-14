// Manual probe: opens the Grid Panel's USB port, runs every byte through the
// real PanelFrameDecoder, and prints what comes out. Run:
//   dart run tool/panel_tap.dart [/dev/cu.usbmodemXXXX]
//
// Needs NO Flutter, NO Xcode and NO app build — which is the whole point of
// keeping panel_frame.dart free of Flutter imports. It is how the framing is
// checked against a real device instead of against an idea of one.
//
// Useful even before the firmware speaks this protocol: pointed at the stock
// firmware it sees boot logs and ordinary console chatter, i.e. exactly the
// noise the decoder has to walk through, and the counters below say whether it
// did so without inventing a frame out of it.
import 'dart:async';
import 'dart:io';

import 'package:grid_app/infrastructure/panel/panel_frame.dart';

/// The panel's native USB interface — Espressif's USB-Serial-JTAG.
///
/// The other port on this board is a WCH CH343 UART bridge (1a86:55d3) which
/// carries the console; the protocol belongs on this one.
const _vendorId = '0x303a';
const _productId = '0x1001';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? args.first : await _pickPort();
  if (port == null) exit(1);

  stdout.writeln('port: $port');

  // Put the tty in raw mode before reading a byte of it. Without this the line
  // discipline is free to translate CR/LF and act on control characters, which
  // silently corrupts binary payloads — and PCM is full of bytes that look
  // like control characters.
  final stty = await Process.run('stty', ['-f', port, 'raw', '-echo']);
  if (stty.exitCode != 0) {
    stderr.writeln('stty failed: ${stty.stderr}');
    exit(1);
  }

  final decoder = PanelFrameDecoder();
  var frames = 0;
  var bytes = 0;

  final file = File(port);
  late final StreamSubscription<List<int>> sub;
  sub = file.openRead().listen(
    (chunk) {
      bytes += chunk.length;
      for (final frame in decoder.feed(chunk)) {
        frames++;
        final kind =
            frame.type?.name ??
            'unknown(0x'
                '${frame.typeCode.toRadixString(16)})';
        final body = frame.type == PanelFrameType.json
            ? frame.text
            : '${frame.payload.length} bytes';
        stdout.writeln('frame #$frames  v${frame.version}  $kind  $body');
      }
    },
    onError: (Object e) {
      stderr.writeln('read error: $e');
      sub.cancel();
    },
  );

  // A status line rather than a running dump: the interesting number on a port
  // that is not speaking this protocol yet is how much was discarded WITHOUT
  // any frame being invented out of it.
  Timer.periodic(const Duration(seconds: 2), (_) {
    stdout.writeln(
      '  ${bytes}B in · $frames frames · '
      '${decoder.discardedBytes}B discarded · '
      '${decoder.corruptFrames} corrupt',
    );
  });

  stdout.writeln('listening — ^C to stop');
  await ProcessSignal.sigint.watch().first;
  await sub.cancel();
  stdout.writeln(
    '\n$bytes bytes, $frames frames, '
    '${decoder.discardedBytes} discarded, '
    '${decoder.corruptFrames} corrupt',
  );
  exit(0);
}

/// Find the panel's port, or explain why it could not.
Future<String?> _pickPort() async {
  final candidates =
      Directory('/dev')
          .listSync()
          .map((e) => e.path)
          .where((p) => p.startsWith('/dev/cu.usbmodem'))
          .toList()
        ..sort();

  if (candidates.isEmpty) {
    stderr.writeln('no /dev/cu.usbmodem* — is the panel plugged in?');
    await _reportUsb();
    return null;
  }
  if (candidates.length == 1) return candidates.single;

  // Both of this board's ports enumerate, so "exactly one" is the exception
  // rather than the rule. Naming the wrong one gets you the console, which
  // looks like a link that is up but never speaks.
  stderr.writeln('several ports — pass one explicitly:');
  for (final c in candidates) {
    stderr.writeln('  $c');
  }
  await _reportUsb();
  return null;
}

/// Print what the USB tree says about the panel, as a hint for choosing.
Future<void> _reportUsb() async {
  final result = await Process.run('system_profiler', ['SPUSBDataType']);
  final text = result.stdout as String;
  final espressif = text.contains(_vendorId) || text.contains('Espressif');
  stderr.writeln(
    espressif
        ? 'USB tree does show an Espressif device ($_vendorId:$_productId) — '
              'its port is the one to use.'
        : 'USB tree shows no Espressif device; only the CH343 console port '
              'is likely present.',
  );
}
