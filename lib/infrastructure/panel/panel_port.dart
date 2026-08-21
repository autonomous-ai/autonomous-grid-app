/// The [PanelTransport] that runs over a real USB cable.
///
/// Everything awkward about talking to a panel lives here, so [PanelLink] and
/// the message layer above it stay pure enough to be driven from a test or from
/// `tool/panel_tap.dart` with no device on the desk:
///
/// - **Which port.** The board enumerates twice. Only the native USB interface
///   (`303a:1001`) carries this protocol; the other is a console. So the port is
///   found by USB id, never by name or by "the only one there".
/// - **Raw mode.** The tty's line discipline mangles binary payloads until it is
///   turned off, and a mangled frame is indistinguishable from a bad cable.
/// - **It comes and goes.** The panel reboots — after a flash, after a crash,
///   whenever the cable is nudged — and the port disappears with it. Reopening
///   is the normal case, not the failure case.
///
/// Free of Flutter, like the rest of this folder.
library;

import 'dart:async';
import 'dart:io';

import 'panel_link.dart';
import 'panel_silence.dart';

/// The panel's **native** USB interface — Espressif's USB-Serial-JTAG.
///
/// The board's other port is a WCH CH343 UART bridge (`1a86:55d3`) carrying the
/// console. Opening that one gives a link that opens, stays open and only ever
/// delivers log text — which reads as a device that never speaks rather than as
/// the wrong port, and is why this is matched on the USB id and nothing else.
const int kPanelUsbVendorId = 0x303a;
const int kPanelUsbProductId = 0x1001;

/// The serial device of the USB device with [vendorId] and [productId] in the
/// output of `ioreg -r -c IOUSBHostDevice -l`, or null when it is not there.
///
/// Pure, and public, because this is the half that is easy to get wrong and
/// impossible to check by reading: `ioreg` prints a *tree*, and the ids and the
/// device path are on different nodes of it. The USB device node carries
/// `idVendor`/`idProduct`; the path (`IOCalloutDevice`) hangs two levels below
/// it, under the CDC driver's `IOSerialBSDClient`. So a match arms the subtree
/// and the first path inside that subtree wins.
///
/// Nesting is read off the column `+-o` starts at, which is how ioreg draws
/// depth. It matters: the same device appears more than once in one dump (once
/// under the hub it is plugged into, once as its own root), and a flat scan
/// pairs a vendor id with a path belonging to whatever came next.
String? panelPortIn(
  String ioreg, {
  int vendorId = kPanelUsbVendorId,
  int productId = kPanelUsbProductId,
}) {
  // Depth of the outermost node that is the panel, or null while the walk is
  // outside one.
  int? panelDepth;
  var depth = 0;
  var vendorSeen = false;
  var productSeen = false;

  for (final line in ioreg.split('\n')) {
    final node = line.indexOf('+-o ');
    if (node >= 0) {
      depth = node;
      vendorSeen = false;
      productSeen = false;
      // Back out to a sibling or an uncle: whatever matched is no longer an
      // ancestor of what comes next.
      if (panelDepth != null && depth <= panelDepth) panelDepth = null;
      continue;
    }
    if (line.contains('"idVendor" = $vendorId')) vendorSeen = true;
    if (line.contains('"idProduct" = $productId')) productSeen = true;
    if (vendorSeen && productSeen) panelDepth ??= depth;
    if (panelDepth == null) continue;

    final callout = _calloutDevice.firstMatch(line);
    if (callout != null) return callout.group(1);
  }
  return null;
}

final _calloutDevice = RegExp(r'"IOCalloutDevice" = "([^"]+)"');

/// Where the panel is plugged in, or null when it is not.
///
/// Cheap when the answer is no, which is the common case and runs every few
/// seconds for the life of the app: a directory listing rules out "no USB
/// serial port at all" before `ioreg` — which costs the better part of a
/// second — is run at all.
///
/// TODO(BE): macOS only. `ioreg` and `stty -f` are both BSD, and Linux names
/// these ports `/dev/ttyACM*`; on Linux and Windows this reports no panel
/// rather than pretending to look. The device half is developed on macOS, so
/// that is where the first milestone lands.
Future<String?> findPanelPort() async {
  if (!Platform.isMacOS) return null;
  if (!_hasUsbSerialPort()) return null;

  // BY ABSOLUTE PATH, and wrapped. `ioreg` lives in /usr/sbin, which
  // a GUI app does not necessarily inherit: launched from Finder, this process
  // gets launchd's PATH, not a shell's. Called by bare name it threw
  // `ProcessException: No such file or directory` on a freshly set-up Mac
  // (2026-08-20), and because nothing caught it the exception left this
  // function, took `_attach` with it and the panel never connected at all —
  // with the cable plugged in and the port sitting there in /dev.
  //
  // Which is the opposite of what this function promises three lines up: it
  // reports "no panel" rather than pretending to look. A tool it cannot run is
  // exactly that case, not a reason to bring the link down.
  final ProcessResult ioreg;
  try {
    ioreg = await Process.run('/usr/sbin/ioreg', [
      '-r',
      '-c',
      'IOUSBHostDevice',
      '-l',
      '-w0',
    ]);
  } on ProcessException {
    return null;
  }
  if (ioreg.exitCode != 0) return null;
  final out = ioreg.stdout;
  return out is String ? panelPortIn(out) : null;
}

/// Whether this computer has any USB CDC serial port at all.
bool _hasUsbSerialPort() {
  try {
    return Directory(
      '/dev',
    ).listSync().any((e) => e.path.startsWith('/dev/cu.usbmodem'));
  } on FileSystemException {
    return false;
  }
}

/// A [PanelTransport] over the panel's USB serial port, which reopens itself
/// whenever the panel comes back.
///
/// Built by `panelLinkProvider` and started by `PanelScope` — construction
/// opens nothing, so the provider graph never touches a cable.
class PanelPort implements PanelTransport {
  PanelPort({
    Future<String?> Function()? locate,
    void Function(String message)? log,
    Duration retry = const Duration(seconds: 3),
    Duration silence = kPanelSilenceLimit,
  }) : _locate = locate ?? findPanelPort,
       _log = log ?? _silent,
       _retry = retry,
       _watch = PanelSilenceWatch(limit: silence);

  /// How the port is found — injected so this can be driven by a pipe.
  final Future<String?> Function() _locate;

  /// Where attaching, detaching and failing to open are reported. Passed in
  /// rather than imported: `appLogProvider` is Riverpod, and this file is one
  /// of the few in the app that a plain `dart:io` script can run.
  final void Function(String message) _log;

  /// How long to wait before looking again.
  final Duration _retry;

  final _incoming = StreamController<List<int>>();
  StreamSubscription<List<int>>? _reader;

  /// A [RandomAccessFile] rather than the [IOSink] from `openWrite`, and the
  /// reason is measured rather than stylistic: **both `openWrite` and
  /// `open(FileMode.writeOnlyAppend)` fail on this device with
  /// `Illegal seek, errno = 29`.** Append asks the OS to seek to the end, and a
  /// character device has no end to seek to.
  ///
  /// The failure is late and looks like something else. Opening succeeds, the
  /// panel's `hello` arrives and parses, and only the *reply* throws — so the
  /// symptom is a link that connects, reads correctly, answers nothing, and
  /// reconnects a few seconds later forever.
  RandomAccessFile? _writer;
  Timer? _retryTimer;

  /// The liveness check, and the only thing standing between a rebooted panel and
  /// a link that stays dead until someone restarts the app. See
  /// [PanelSilenceWatch] for what was measured.
  final PanelSilenceWatch _watch;

  /// Polls [_watch] while a port is open. Cheap — one clock comparison — and it
  /// runs several times inside the window so a stale handle is noticed near the
  /// limit rather than a whole limit late.
  Timer? _watchTimer;
  bool _running = false;
  String? _port;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  /// The port that is open right now, or null while nothing is attached.
  String? get port => _port;

  /// Start looking for the panel, and keep the port open from then on.
  ///
  /// Returns after the **first** attempt, attached or not: no panel plugged in
  /// is the ordinary state of this app, and startup must not wait on one.
  /// Everything after that happens on the retry timer.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _attach();
  }

  /// Write bytes if there is a panel to write them to.
  ///
  /// Dropped when there is not, deliberately: every message the app sends is
  /// either an answer to something the panel just said or a snapshot of state
  /// it will ask for again on the next `hello`. Queueing them would deliver a
  /// pile of stale answers to a panel that has since rebooted.
  @override
  void send(List<int> bytes) {
    final writer = _writer;
    if (writer == null) return;
    try {
      // Synchronous on purpose: a frame is at most 8 KB to a local character
      // device, and an async write would let a second `send` interleave with
      // this one and split a frame down the middle on the wire.
      writer.writeFromSync(bytes);
    } on FileSystemException catch (e) {
      // The cable went before the write did.
      _detach('write failed: ${e.message}');
    }
  }

  /// Stop looking, and let the port go. Safe to call twice, and safe to call
  /// alongside [PanelLink.close], which also calls it.
  @override
  Future<void> close() async {
    _running = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    await _release();
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// One attempt to find the panel and open it.
  Future<void> _attach() async {
    if (!_running || _reader != null) return;

    final port = await _locate();
    if (port == null || !_running) return _retryLater();

    // Raw mode before a single byte is read. Left cooked, the line discipline
    // translates CR/LF and acts on control characters — and a PCM chunk is full
    // of bytes that look like control characters. The corruption is silent: the
    // frames still arrive, they just fail their CRC.
    //
    // BY ABSOLUTE PATH, and wrapped, for the same reason `ioreg` is one function
    // up: a GUI app launched from Finder gets launchd's PATH, not a shell's, and
    // a bare name is a bet on what that contains. `ioreg` lost that bet on a
    // freshly set-up Mac (2026-08-20) and, being uncaught, took `_attach` down
    // with it — the retry was never armed, so the panel was never looked for
    // again for the life of the process. `stty` sits one line further along the
    // same path and was left holding the same bet; a machine missing /usr/sbin
    // is a fair candidate for missing /bin.
    //
    // The signature is what makes this worth pre-empting: no port, no log line,
    // and a panel spinning on its boot screen forever with the cable plugged in.
    final ProcessResult raw;
    try {
      raw = await Process.run('/bin/stty', ['-f', port, 'raw', '-echo']);
    } on ProcessException catch (e) {
      _log('could not run stty for $port: ${e.message}');
      return _retryLater();
    }
    if (raw.exitCode != 0) {
      _log('stty failed on $port: ${raw.stderr}');
      return _retryLater();
    }
    if (!_running) return;

    final file = File(port);
    try {
      // writeOnly, NOT writeOnlyAppend — see the field's own note. Truncation
      // is what `writeOnly` would do to a regular file and is a no-op on a
      // character device, while append needs a seek this device refuses.
      _writer = file.openSync(mode: FileMode.writeOnly);
      _reader = file.openRead().listen(
        _onBytes,
        onError: (Object e) => _detach('read failed: $e'),
        onDone: () => _detach('port closed'),
        cancelOnError: true,
      );
    } on FileSystemException catch (e) {
      _log('could not open $port: ${e.message}');
      await _release();
      return _retryLater();
    }
    // No `done` future to watch, unlike an IOSink: a RandomAccessFile reports a
    // failed write to the caller, which [send] already turns into a reconnect.

    _port = port;
    _bytesIn = 0;
    _watch.opened(DateTime.now());
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_watch.isStale(DateTime.now())) return;
      // Not phrased as a guess. There is exactly one way to reach this line —
      // the handle no longer reaches the panel — and naming the cause here is
      // what keeps the next person from reading it as a flaky cable.
      _detach(
        'nothing heard for ${_watch.limit.inSeconds}s after $_bytesIn bytes — the '
        'port still opens and still accepts writes, so the panel rebooted and '
        'this handle is stale',
      );
    });
    _log('attached to $port');
  }

  void _onBytes(List<int> chunk) {
    if (_incoming.isClosed) return;
    // AN EMPTY CHUNK IS NOT A SIGN OF LIFE, and this line is the whole reason the
    // first version of the watchdog below never fired. A handle onto a panel that
    // has rebooted keeps its read stream open and delivers nothing but zero-length
    // reads — forever, without ever completing — so counting a chunk rather than a
    // byte made the deadest possible link look like the busiest one.
    if (chunk.isEmpty) return;
    _bytesIn += chunk.length;
    _watch.heard(DateTime.now());
    _incoming.add(chunk);
  }

  /// Bytes read since the port was opened. Only ever reported in the detach
  /// message, where it separates "the panel went away" from "this handle never
  /// carried anything".
  int _bytesIn = 0;

  /// The panel went away. Usually because it rebooted — which is what flashing
  /// it does, several times a session — so this is a reconnect, not a failure,
  /// and the message stream stays open across it.
  void _detach(String why) {
    if (_reader == null && _writer == null) return;
    _log('detached: $why');
    unawaited(_release());
    _retryLater();
  }

  Future<void> _release() async {
    _watchTimer?.cancel();
    _watchTimer = null;
    _watch.closed();
    final reader = _reader;
    final writer = _writer;
    _reader = null;
    _writer = null;
    _port = null;
    await reader?.cancel();
    try {
      await writer?.close();
    } on Object {
      // Closing a sink whose device has been unplugged throws the same failure
      // that got us here, already logged by [_detach].
    }
  }

  void _retryLater() {
    if (!_running) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry, () => unawaited(_attach()));
  }

  static void _silent(String _) {}
}
