/// The message layer over [PanelFrameDecoder] — bytes in, typed messages out.
///
/// Sits between the framing and anything that knows what a project is, and
/// knows about neither: it does not open the port (that is [PanelTransport])
/// and it does not touch app state. That split is what lets the whole protocol
/// be exercised from a scratch script against a real device, which is how it
/// gets checked.
///
/// Free of Flutter, for the same reason `ConnectorBridge` is.
library;

import 'dart:async';

import 'panel_frame.dart';
import 'panel_message.dart';
import 'panel_stranger.dart';

/// Somewhere bytes come from and go to.
///
/// An interface rather than a serial port directly so the link can be driven
/// by a pair of pipes in a test, or by a fake device, without a cable.
abstract interface class PanelTransport {
  /// Bytes as they arrive, in whatever sizes the driver hands over.
  Stream<List<int>> get incoming;

  /// Write bytes. May be called before [incoming] has produced anything.
  void send(List<int> bytes);

  /// Let this port go: it is another product's device, not a panel.
  ///
  /// Distinct from [close], which ends the transport for good. This one detaches
  /// and keeps looking — the user may have a real panel on another port, or may
  /// plug one into this socket later — but it must not reopen *this* port for a
  /// while, or the two apps trade the tty back and forth and neither works.
  ///
  /// On the interface rather than on `PanelPort` alone because [PanelLink] is
  /// what can tell: ownership is decided by whether frames decode, and the
  /// transport only ever sees bytes.
  void disown(String why);

  Future<void> close();
}

/// Frames and unframes messages over a [PanelTransport].
class PanelLink {
  PanelLink(this._transport, {void Function(String message)? log})
    : _log = log ?? _silent {
    _sub = _transport.incoming.listen(
      _onBytes,
      onError: _messages.addError,
      onDone: _messages.close,
    );
  }

  final PanelTransport _transport;

  /// Where a port being let go is reported. Passed in rather than imported, so
  /// this file stays runnable from a plain `dart:io` script.
  final void Function(String message) _log;

  final _decoder = PanelFrameDecoder();

  /// Whether the thing on the other end is somebody else's device.
  final _stranger = PanelStrangerWatch();
  final _messages = StreamController<PanelInbound>.broadcast();
  late final StreamSubscription<List<int>> _sub;

  /// Messages from the panel, already parsed.
  ///
  /// Broadcast because more than one thing legitimately listens: the controller
  /// that answers, and the debug view that shows traffic.
  Stream<PanelInbound> get messages => _messages.stream;

  /// PCM chunks from a voice capture, kept off [messages].
  ///
  /// Audio is a different shape of traffic — high rate, no meaning per chunk —
  /// and folding it into the message stream would make every listener filter
  /// it out again.
  Stream<List<int>> get audio => _audio.stream;
  final _audio = StreamController<List<int>>.broadcast();

  /// Bytes the framing threw away, and frames it refused.
  ///
  /// Surfaced because a rising count is the difference between "quiet link"
  /// and "the two sides disagree about the format".
  int get discardedBytes => _decoder.discardedBytes;
  int get corruptFrames => _decoder.corruptFrames;

  /// Frames carrying a type this build has no case for.
  int get unknownFrames => _unknownFrames;
  int _unknownFrames = 0;

  /// Send one JSON control message, built by [PanelOutbound].
  void send(String json) => _transport.send(encodePanelJson(json));

  /// Send one slice of a firmware image, in order from offset 0.
  ///
  /// Its own frame type rather than base64 inside a control message: the image
  /// is a megabyte, base64 would make it a third more of one, and the device
  /// writes these straight into flash instead of holding the whole thing.
  /// [encodePanelFrame] refuses a slice over the payload cap, so a caller that
  /// cuts the image wrong fails here rather than as noise on the other end.
  void sendFirmware(List<int> slice) =>
      _transport.send(encodePanelFrame(PanelFrameType.firmware, slice));

  void _onBytes(List<int> chunk) {
    _stranger.heard(chunk.length, DateTime.now());
    _letGo();
    for (final frame in _decoder.feed(chunk)) {
      // Anything that decoded settles ownership: the magic AND the CRC both
      // passed, which another product's stream cannot manage.
      _stranger.decoded();
      switch (frame.type) {
        case PanelFrameType.json:
          final message = PanelInbound.parse(frame.text);
          // THE POSITIVE MATCH, at the earliest point it can be made. A greeting
          // that does not name this product is not forwarded — not answered with
          // a refusal, not logged as unreadable, not seen by the controller at
          // all. `welcome` is what opens a session, and there is no session to
          // have with somebody else's device.
          if (message is PanelHello && !message.isOurs) {
            _stranger.foreignGreeting();
            _letGo();
            continue;
          }
          _messages.add(message);
        case PanelFrameType.pcm:
          _audio.add(frame.payload);
        case PanelFrameType.firmware:
          // Firmware frames travel app -> device only. One arriving the other way
          // is a peer doing something this build has no meaning for, which is the
          // same situation as an unknown type and gets the same counter.
          _unknownFrames++;
        case null:
          // A frame that decoded cleanly but names a type this build predates.
          // Counted rather than dropped silently: it means the firmware is
          // ahead of the app, which is a state worth showing.
          _unknownFrames++;
      }
    }
  }

  /// Let the port go when the traffic on it is not addressed to this app.
  ///
  /// Called as bytes arrive rather than on a timer: the two conditions it reads
  /// — bytes seen, nothing decoded — only ever change when bytes arrive, so a
  /// timer would be a second clock measuring the same thing. It costs one clock
  /// comparison per chunk, and returns immediately in the ordinary case.
  void _letGo() {
    final why = _stranger.reason(DateTime.now());
    if (why == null) return;
    _log('letting go of the port: $why');
    _stranger.closed();
    _decoder.reset();
    _transport.disown(why);
  }

  static void _silent(String _) {}

  /// Stop listening and release the transport.
  ///
  /// Resets the decoder as well: leftover bytes belong to a session that has
  /// ended, and a reopened port must not start on half a frame from the last.
  Future<void> close() async {
    await _sub.cancel();
    _decoder.reset();
    await _messages.close();
    await _audio.close();
    await _transport.close();
  }
}
