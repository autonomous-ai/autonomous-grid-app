import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/panel/panel_firmware.dart';
import '../../../infrastructure/panel/panel_link.dart';
import '../../../infrastructure/panel/panel_message.dart';

/// How many bytes may be in flight before the app waits for `fw.progress`.
///
/// This is a window, not a chunk size: the app keeps this much unacknowledged
/// and tops it up on every progress report.
///
/// **16 KB is measured, and it is a hardware limit, not a preference.** The
/// panel's USB Serial/JTAG peripheral has no back-pressure at all: its ISR
/// drains the hardware FIFO unconditionally and pushes into a ring buffer
/// without checking whether the push succeeded, so bytes that do not fit are
/// dropped there and *the host is never told* — no NAK, no short write, nothing
/// this side can observe. Sending faster than the panel reads does not slow the
/// app down, it shreds the stream, and the damage surfaces minutes later as a
/// sha256 that does not match, if it surfaces at all.
///
/// So the number is fixed by the panel's receive ring (32 KB, `panel_link.c`)
/// and by how long its reader task is blocked writing a slice to flash. Two
/// slices in flight against a ring that holds four leaves room for scheduling
/// jitter. **`kPanelFirmwareWindowBytes`, `USJ_RX_BUF` and `PROGRESS_EVERY` are
/// one decision spread across two languages** — moving any of them alone brings
/// the bug back.
///
/// This replaces an earlier 128 KB that was, as its own TODO admitted, a
/// judgement rather than a measurement. The first transfer against a real panel
/// wrote **0 of 1342160 bytes**: the app pushed the whole window before the
/// first ack was due and almost none of it survived.
const int kPanelFirmwareWindowBytes = 16 * 1024;

/// How long the app waits for the panel to say it wrote something.
///
/// An update that stops halfway leaves the panel drawing a progress bar that
/// never moves. Giving up puts the link back in a state where the next `hello`
/// can offer again, which is the only way out that does not need the cable
/// pulled.
const Duration kPanelFirmwareStall = Duration(seconds: 30);

/// Where a firmware handover has got to.
///
/// Sealed rather than a pair of booleans because the three states answer
/// different questions: whether an offer is outstanding, whether bytes are
/// moving, and whether the link is free for the next `hello` to offer again.
sealed class PanelFirmwarePhase {
  const PanelFirmwarePhase();
}

/// Nothing offered, nothing moving.
class PanelFirmwareIdle extends PanelFirmwarePhase {
  const PanelFirmwareIdle();
}

/// An offer is out and the panel has not answered.
///
/// Declining is simply not answering (`docs/protocol.md` §2), so this state can
/// last for the rest of the session — which is why it blocks a second offer
/// rather than timing out into one.
class PanelFirmwareOffered extends PanelFirmwarePhase {
  const PanelFirmwareOffered(this.version);

  final String version;
}

/// The image is being written to the panel.
class PanelFirmwareSending extends PanelFirmwarePhase {
  const PanelFirmwareSending({
    required this.version,
    required this.sent,
    required this.written,
    required this.size,
  });

  final String version;

  /// Bytes handed to the link.
  final int sent;

  /// Bytes the panel says are in flash.
  final int written;

  final int size;
}

/// Offers the bundled firmware to a panel and streams it when accepted.
///
/// Kept apart from `PanelController` because it is a small state machine with a
/// clock in it, and because everything it does is driven by four messages the
/// controller merely forwards. It never decides *whether* to offer — that needs
/// app state (is a turn running?) it has no business reading.
class PanelFirmwareUpdater {
  PanelFirmwareUpdater({
    required PanelLink link,
    required AppLog log,
    this.onGaveUp,
    this.onWrote,
    this.windowBytes = kPanelFirmwareWindowBytes,
    this.stall = kPanelFirmwareStall,
  }) : _link = link,
       _log = log;

  final PanelLink _link;
  final AppLog _log;
  final int windowBytes;
  final Duration stall;

  /// Called with the image version when a handover ends without the panel
  /// writing it — the panel refused, or it stopped reporting progress.
  ///
  /// Exists so the caller can stop offering the same image over and over.
  /// Accepting an offer makes the panel erase a flash slot before it answers, so
  /// an offer that keeps failing is not merely noise in a log: it is erase
  /// cycles spent on a device, every fifteen seconds, for as long as the cable
  /// is in. Not called for [reset], which is the cable going or the app closing
  /// — nothing was learned about the image there.
  final void Function(String version)? onGaveUp;

  /// Called with the image version when the panel confirms it has written one.
  ///
  /// The counterpart to [onGaveUp], and the only moment at which this app has
  /// actually spent one of a board's erase cycles — an offer that is declined,
  /// or that fails halfway, writes nothing. Anything counting flashes has to
  /// count them here.
  final void Function(String version)? onWrote;

  PanelFirmwareImage? _image;
  List<Uint8List> _slices = const [];
  int _next = 0;
  int _sent = 0;
  int _written = 0;
  bool _accepted = false;
  bool _pumping = false;
  Timer? _stallTimer;

  /// Bumped whenever the handover is abandoned, so a send loop suspended
  /// between two frames can tell that the transfer it belongs to is over.
  int _session = 0;

  /// What is happening right now.
  PanelFirmwarePhase get phase {
    final image = _image;
    if (image == null) return const PanelFirmwareIdle();
    if (!_accepted) return PanelFirmwareOffered(image.version);
    return PanelFirmwareSending(
      version: image.version,
      sent: _sent,
      written: _written,
      size: image.size,
    );
  }

  /// Whether an offer or a transfer is already outstanding.
  bool get busy => _image != null;

  /// Offer [image] to the panel. Returns whether an offer went out.
  ///
  /// Refuses to start a second one: the panel is either thinking about the
  /// first or writing it, and a fresh `fw.offer` mid-transfer would leave the
  /// two sides disagreeing about which image the frames belong to.
  bool offer(PanelFirmwareImage image) {
    if (busy) return false;
    _image = image;
    _slices = panelFirmwareSlices(image.bytes);
    _next = 0;
    _sent = 0;
    _written = 0;
    _accepted = false;
    _log.info(
      'panel',
      'Offering firmware ${image.version} to the panel '
          '(${image.size} bytes in ${_slices.length} frames)',
    );
    _link.send(
      PanelOutbound.firmwareOffer(
        version: image.version,
        size: image.size,
        sha256: image.sha256,
      ),
    );
    return true;
  }

  /// The panel accepted. Start sending.
  void accepted() {
    final image = _image;
    if (image == null) {
      // An accept for an offer this session never made — a panel answering an
      // offer from before the app restarted. Sending an image it is not
      // expecting the sha256 of would fail its own verification anyway.
      _log.warn('panel', 'The panel accepted a firmware update nobody offered');
      return;
    }
    if (_accepted) return;
    _accepted = true;
    _log.info('panel', 'The panel accepted firmware ${image.version}');
    _armStall();
    unawaited(_pump());
  }

  /// The panel has [written] bytes in flash. Top the window back up.
  void progress(int written) {
    if (_image == null || !_accepted) return;
    // Never backwards: a reordered or repeated report must not shrink the
    // window and stall a transfer that is in fact moving.
    _written = math.max(_written, written);
    _armStall();
    unawaited(_pump());
  }

  /// The panel verified the image and is rebooting into it.
  void done() {
    final image = _image;
    if (image == null) return;
    _log.info(
      'panel',
      'The panel wrote firmware ${image.version} and is rebooting into it',
    );
    _finish();
    onWrote?.call(image.version);
  }

  /// The panel refused or failed. It keeps running what it had.
  void failed(String message) {
    final image = _image;
    if (image == null) return;
    _log.warn('panel', 'The panel could not take the firmware: $message');
    _finish();
    onGaveUp?.call(image.version);
  }

  /// Abandon whatever is in flight — the cable went, or the app is closing.
  void reset() {
    if (_image == null) return;
    _log.info('panel', 'Firmware handover abandoned');
    _finish();
  }

  void _finish() {
    _session++;
    _image = null;
    _slices = const [];
    _next = 0;
    _sent = 0;
    _written = 0;
    _accepted = false;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _armStall() {
    _stallTimer?.cancel();
    _stallTimer = Timer(stall, () {
      final image = _image;
      _log.warn(
        'panel',
        'The panel stopped reporting progress at $_written of '
            '${image?.size ?? 0} bytes — giving up on this update',
      );
      _finish();
      if (image != null) onGaveUp?.call(image.version);
    });
  }

  /// Send frames until the window is full or the image runs out.
  ///
  /// One frame per turn of the event loop rather than a burst: a frame is a
  /// synchronous write to a character device, and 16 of them back to back would
  /// hold the isolate long enough for the panel's own messages — Stop, most of
  /// all — to queue behind an update.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    final session = _session;
    try {
      while (_next < _slices.length && _sent - _written < windowBytes) {
        final slice = _slices[_next++];
        _link.sendFirmware(slice);
        _sent += slice.length;
        await Future<void>.delayed(Duration.zero);
        // The transfer ended while this loop was suspended.
        if (session != _session) return;
      }
    } finally {
      _pumping = false;
    }
  }
}
