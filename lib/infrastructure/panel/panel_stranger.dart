/// When to conclude that an open port belongs to another product, and let it go.
///
/// [kPanelMagic] stops this app from *understanding* another product's device,
/// and [kPanelProduct] stops it from *answering* one. Neither stops it from
/// **holding the port**, and that is its own failure: a tty handed to two
/// readers does not deadlock, it interleaves — each takes a share of the other's
/// bytes, so frames arrive shredded and CRCs fail on **both** sides. Measured on
/// this hardware while chasing a different bug: five readers on one stream cost
/// 18 of 22 greetings. Two apps open at once is that situation whether or not
/// either one ever writes firmware.
///
/// So this decides one thing — *is anybody talking to me on this port?* — and
/// the port layer acts on it.
///
/// Pulled out of [PanelLink] as plain logic with the clock passed in, for the
/// same reason [PanelSilenceWatch] was pulled out of `PanelPort`: the decision
/// is the part worth testing, and the plumbing around it is checked by plugging
/// a board in.
library;

/// How long a port may deliver bytes that never become a frame before the app
/// concludes the bytes are not addressed to it.
///
/// **Deliberately generous, and the asymmetry is what makes it safe.** This
/// app's own panel is silent-then-noisy across a reboot — ROM and bootloader
/// text arrive before the firmware frames anything — so a short window would
/// evict a board that was merely booting. Another product's device, by
/// contrast, emits frames *continuously*, so "many bytes, zero frames" is a
/// clean signal rather than a marginal one, and waiting longer costs nothing
/// but a few seconds on a port that was never ours.
const Duration kPanelStrangerLimit = Duration(seconds: 12);

/// How long a port stays disowned once it has been let go.
///
/// The number matters less than it looks. A tty is exclusive on macOS: the
/// moment this app releases it the other product's daemon takes it, and later
/// probes then fail to *open* it rather than stealing it back. So this only
/// decides how quickly the app would notice the user unplugging that device and
/// plugging a real panel into the same socket.
const Duration kPanelStrangerCooldown = Duration(seconds: 60);

/// Whether the device on the other end of an open port is somebody else's.
class PanelStrangerWatch {
  PanelStrangerWatch({this.limit = kPanelStrangerLimit});

  /// How long bytes may arrive without a frame before the verdict lands.
  final Duration limit;

  /// When the first byte arrived, or null while nothing has been heard.
  ///
  /// The window runs from the first byte rather than from the port opening, and
  /// that is not a convenience: a port that is open and silent is not suspicious
  /// in the first place — [isStranger] already requires bytes — so timing from
  /// the open would only shorten the window for a device that started talking
  /// late, which is exactly what this app's own panel does after a reboot.
  DateTime? _first;

  /// Bytes seen on this port. The lower half of the signal: a port that has
  /// delivered *nothing* is a quiet panel, not a foreign one, and evicting it
  /// would reopen the same port forever on a machine with a sleeping board.
  int _bytes = 0;

  /// Whether anything at all has decoded on this port.
  ///
  /// One frame is enough, permanently: the two products cannot both produce a
  /// frame that passes this app's magic *and* its CRC, so a single clean decode
  /// settles ownership for the life of the port.
  bool _decoded = false;

  /// A greeting arrived naming another product — the unambiguous case, which
  /// needs no window at all.
  bool _foreignGreeting = false;

  /// Bytes arrived — any bytes, including the boot text this app never wrote.
  /// The first call starts the window.
  void heard(int count, DateTime at) {
    if (count <= 0) return;
    _first ??= at;
    _bytes += count;
  }

  /// A frame decoded cleanly. Settles it: this port is ours.
  void decoded() => _decoded = true;

  /// A `hello` decoded and named a product this build is not.
  ///
  /// Only reachable if the two products share framing — which they no longer do
  /// — so in practice this fires for a Grid panel talking to a Grid app and
  /// never for a Harness dial. It is kept because it is the case that survives
  /// anyone re-unifying the magic, and because it is what makes the log say
  /// *which* product rather than *nothing parsed*.
  void foreignGreeting() => _foreignGreeting = true;

  /// Nothing is attached.
  void closed() {
    _first = null;
    _bytes = 0;
    _decoded = false;
    _foreignGreeting = false;
  }

  /// Bytes seen on this port that never became a frame — the number worth
  /// putting in the log line, because it is the difference between "another
  /// product is talking over me" and "this cable is dead".
  int get bytes => _bytes;

  /// Whether to let this port go.
  bool isStranger(DateTime now) {
    if (_foreignGreeting) return true;
    if (_decoded) return false;
    final first = _first;
    if (first == null) return false;
    return now.difference(first) > limit;
  }

  /// Why, in the words the log should carry. Null when [isStranger] is false.
  String? reason(DateTime now) {
    if (!isStranger(now)) return null;
    if (_foreignGreeting) {
      return 'it greeted as another product';
    }
    return '$_bytes bytes arrived in ${limit.inSeconds}s and not one frame '
        'decoded — this board is not speaking Grid';
  }
}
