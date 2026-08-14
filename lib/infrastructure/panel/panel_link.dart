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

/// Somewhere bytes come from and go to.
///
/// An interface rather than a serial port directly so the link can be driven
/// by a pair of pipes in a test, or by a fake device, without a cable.
abstract interface class PanelTransport {
  /// Bytes as they arrive, in whatever sizes the driver hands over.
  Stream<List<int>> get incoming;

  /// Write bytes. May be called before [incoming] has produced anything.
  void send(List<int> bytes);

  Future<void> close();
}

/// Frames and unframes messages over a [PanelTransport].
class PanelLink {
  PanelLink(this._transport) {
    _sub = _transport.incoming.listen(
      _onBytes,
      onError: _messages.addError,
      onDone: _messages.close,
    );
  }

  final PanelTransport _transport;
  final _decoder = PanelFrameDecoder();
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

  void _onBytes(List<int> chunk) {
    for (final frame in _decoder.feed(chunk)) {
      switch (frame.type) {
        case PanelFrameType.json:
          _messages.add(PanelInbound.parse(frame.text));
        case PanelFrameType.pcm:
          _audio.add(frame.payload);
        case null:
          // A frame that decoded cleanly but names a type this build predates.
          // Counted rather than dropped silently: it means the firmware is
          // ahead of the app, which is a state worth showing.
          _unknownFrames++;
      }
    }
  }

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
