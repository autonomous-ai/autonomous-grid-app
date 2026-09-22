/// What the Phone screen is showing, as four states and nothing in between.
///
/// A sealed type rather than a handful of booleans, so the screen cannot be
/// asked to draw "sharing, but also failed" and every branch it does draw is
/// one the compiler made it write.
library;

import 'package:grid_pairing/grid_pairing.dart';

import '../../../infrastructure/pairing_host/device_registry.dart';

/// Where sharing with a phone has got to.
sealed class PhoneSharingState {
  const PhoneSharingState();
}

/// Not sharing. Nothing is listening, no address exists, and no phone can
/// reach this computer — including one that was paired yesterday.
final class PhoneSharingOff extends PhoneSharingState {
  const PhoneSharingOff();
}

/// Starting, with the step it is on.
///
/// The step is shown because opening a tunnel takes about six seconds against
/// Cloudflare, and a spinner that says nothing for six seconds is a spinner
/// people close the window on.
final class PhoneSharingStarting extends PhoneSharingState {
  const PhoneSharingStarting(this.step);

  /// What is being done right now, in the words the screen shows.
  final String step;
}

/// Sharing: there is an address, and phones can reach this computer at it.
final class PhoneSharingLive extends PhoneSharingState {
  const PhoneSharingLive({
    required this.relayHostId,
    required this.publicUrl,
    required this.devices,
    required this.events,
    this.newest,
    this.busy = false,
  });

  /// The id this computer's key owns. Shown so a person has something to name
  /// when two computers are involved; it is not a secret and not a code.
  final String relayHostId;

  /// The `https://` address the tunnel is offering, for a person to open in a
  /// browser and see that it is alive.
  final String publicUrl;

  /// The phones that hold a code for this computer.
  final List<PairedDevice> devices;

  /// Recent activity, newest last.
  final List<String> events;

  /// The phone added a moment ago, whose code the screen is showing large.
  ///
  /// Only the newest, and only until something else happens: a screen that
  /// lists every code at once is a screen nobody can screenshot safely.
  final PairedDevice? newest;

  /// Whether an action is in flight, so the screen can disable its buttons.
  final bool busy;

  /// A copy with the named fields replaced.
  ///
  /// [newest] is not copied forward on purpose — every other action clears it,
  /// which is what keeps a code on screen only while it is being read.
  PhoneSharingLive copyWith({
    String? publicUrl,
    List<PairedDevice>? devices,
    List<String>? events,
    PairedDevice? newest,
    bool? busy,
  }) => PhoneSharingLive(
    relayHostId: relayHostId,
    publicUrl: publicUrl ?? this.publicUrl,
    devices: devices ?? this.devices,
    events: events ?? this.events,
    newest: newest,
    busy: busy ?? this.busy,
  );
}

/// It did not work, and [message] says what to do about it.
final class PhoneSharingFailed extends PhoneSharingState {
  const PhoneSharingFailed(this.message);

  /// Shown on screen as-is, so never a stack trace.
  final String message;
}

/// The connect code for [device], parsed back out of what is stored.
///
/// Null only for a record written by a build that stored something else, which
/// is a row to ignore rather than a reason to fail: the screen shows the phone
/// without a code, and the way back is to add it again.
PairToken? tokenOf(PairedDevice device) => PairToken.tryParse(device.token);
