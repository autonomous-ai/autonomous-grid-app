/// When to stop believing an open port still reaches a panel.
///
/// Pulled out of [PanelPort] as plain logic with the clock passed in, because the
/// port itself cannot be unit-tested — attaching runs `stty` against a character
/// device, and there is no fake for that. The decision is the part worth testing;
/// the plumbing around it is checked by plugging a panel in.
library;

/// How long a panel may say nothing before the app assumes the handle is dead.
///
/// The app pings every 5s and the firmware answers each one, so a healthy link
/// never goes four beats without traffic. Deliberately longer than the device's
/// own 15s rule for the same silence in the other direction, so one late message
/// cannot trip both watchdogs at once and have each blame the other.
const Duration kPanelSilenceLimit = Duration(seconds: 20);

/// Whether the panel has gone quiet for long enough to give up on the handle.
///
/// The failure this exists for has no other symptom, and that is the whole
/// reason it exists. Measured on macOS on 2026-08-17: an ESP32-S3 that reboots
/// — which is what accepting a firmware update makes it do — comes back on a
/// `/dev/cu.usbmodem*` node with the same name, the same inode and the same
/// device numbers. Writes to the old handle keep succeeding, the read stream
/// never completes, and nothing raises. The app went on pinging a dead file
/// while the panel sat two feet away re-introducing itself every fifteen
/// seconds, and only restarting the app or replugging the cable fixed it.
///
/// So silence is the signal, and the app has to supply the traffic it measures:
/// the panel answers every `ping` with a `pong` for exactly this.
class PanelSilenceWatch {
  PanelSilenceWatch({this.limit = kPanelSilenceLimit});

  final Duration limit;

  /// When the panel was last heard from, or null while nothing is attached —
  /// which is not "quiet", it is "nowhere to be quiet". Those must not be the
  /// same state: a machine with no panel plugged in would otherwise look like a
  /// panel that stopped answering, and reattach on a timer forever.
  DateTime? _lastHeard;

  /// A port was just opened. Starts the window, so a handle that was stale
  /// before the first byte ever arrived is still caught.
  void opened(DateTime at) => _lastHeard = at;

  /// Bytes arrived — any bytes. Deliberately not "a pong arrived": a link busy
  /// with a firmware transfer or a voice capture is alive whether or not the
  /// heartbeat is getting a look-in edgewise.
  void heard(DateTime at) => _lastHeard = at;

  /// Nothing is attached.
  void closed() => _lastHeard = null;

  bool isStale(DateTime now) {
    final last = _lastHeard;
    return last != null && now.difference(last) > limit;
  }
}
