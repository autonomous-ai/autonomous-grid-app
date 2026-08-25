import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/grid_paths.dart';
import 'analytics_config.dart';

/// The device id and the visit id every event carries, kept in
/// `~/.grid/app/analytics.json`.
///
/// Two ids, two lifetimes. The **device id** is minted once and never reset —
/// it is what ties a person's first launch to the day they finally shared a
/// model, across sign-in and sign-out. The **visit id** rotates after
/// `AnalyticsLimits.sessionIdle` of quiet, which is how a session is counted.
///
/// The file also carries the user's own switch: `{"enabled": false}` mutes the
/// app, and is preserved by every write here so turning it off stays off.
///
/// App-owned and lenient like the other app stores — a missing, corrupt or
/// hand-edited file reads as "no ids yet" rather than throwing, because the
/// alternative is an analytics detail breaking the launch it was meant to
/// measure. The file is overridable so tests never touch a real grid home.
class AnalyticsIdentityStore {
  AnalyticsIdentityStore({File? file, File? deviceFile, Random? random})
    : _file = file ?? GridPaths.analyticsFile,
      _deviceFile = deviceFile ?? GridPaths.deviceFile,
      _random = random ?? Random.secure();

  final File _file;
  final File _deviceFile;
  final Random _random;

  _StoredIdentity? _state;

  /// How stale the on-disk `last_active_ms` is allowed to get. A write per event
  /// would be an fsync per click; the cost of lagging is that a restart after a
  /// long quiet spell may start a new visit up to a minute early, which is
  /// noise beside a 15-minute window.
  static const Duration _persistEvery = Duration(minutes: 1);

  /// The CLI writes exactly one `device_id = "…"` line into `device.toml`. Read
  /// with a regex rather than the TOML parser: it is one key out of a file this
  /// app does not own, and a parse failure must cost nothing.
  static final RegExp _deviceIdPattern = RegExp(r'device_id\s*=\s*"([^"]+)"');

  /// Whether the user turned tracking off in `~/.grid/app/analytics.json`.
  bool get optedOut => _load().optedOut;

  /// The ids as they stand, without starting a visit or moving the clock —
  /// what the Tracking tab reads. `sessionId` is empty until the first event of
  /// a launch has been tracked.
  ({String pseudoId, String sessionId}) peek() {
    final state = _load();
    return (pseudoId: state.pseudoId, sessionId: state.sessionId);
  }

  /// The ids for an event happening at [now], rotating the visit after a quiet
  /// spell and persisting sparingly (see [_persistEvery]).
  ({String pseudoId, String sessionId}) touch(DateTime now) {
    final state = _load();
    final at = now.millisecondsSinceEpoch;
    final expired =
        state.sessionId.isEmpty ||
        at - state.lastActive > AnalyticsLimits.sessionIdle.inMilliseconds;
    final next = _StoredIdentity(
      pseudoId: state.pseudoId,
      sessionId: expired ? _uuidV4(_random) : state.sessionId,
      lastActive: at,
      optedOut: state.optedOut,
    );
    _state = next;
    if (expired || at - state.lastActive >= _persistEvery.inMilliseconds) {
      _persist(next);
    }
    return (pseudoId: next.pseudoId, sessionId: next.sessionId);
  }

  _StoredIdentity _load() {
    final cached = _state;
    if (cached != null) return cached;
    var json = const <String, Object?>{};
    try {
      if (_file.existsSync()) {
        final decoded = jsonDecode(_file.readAsStringSync());
        if (decoded is Map) json = decoded.cast<String, Object?>();
      }
    } on Object {
      // Corrupt or hand-edited: start over rather than fail the launch.
    }
    final stored = (json['user_pseudo_id'] as String?)?.trim();
    final state = _StoredIdentity(
      pseudoId: stored != null && stored.isNotEmpty ? stored : _newPseudoId(),
      sessionId: (json['session_id'] as String?) ?? '',
      lastActive: (json['last_active_ms'] as num?)?.toInt() ?? 0,
      optedOut: json['enabled'] == false,
    );
    _state = state;
    return state;
  }

  /// A fresh device id: the CLI's `device_id` when this machine has one, else a
  /// new UUID.
  ///
  /// Borrowing the CLI's id rather than minting a second one is what lets an
  /// event be lined up with the device the grid knows about. It is copied here
  /// on first use and then never re-read, so a later `grid login` that rewrites
  /// `device.toml` cannot silently turn this machine into a second visitor.
  String _newPseudoId() => _cliDeviceId() ?? _uuidV4(_random);

  String? _cliDeviceId() {
    try {
      if (!_deviceFile.existsSync()) return null;
      final match = _deviceIdPattern.firstMatch(_deviceFile.readAsStringSync());
      final id = match?.group(1)?.trim();
      return (id == null || id.isEmpty) ? null : id;
    } on Object {
      return null;
    }
  }

  /// Writes the ids back, `enabled` included so a user's opt-out survives.
  void _persist(_StoredIdentity state) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'user_pseudo_id': state.pseudoId,
          'session_id': state.sessionId,
          'last_active_ms': state.lastActive,
          'enabled': !state.optedOut,
        }),
        flush: true,
      );
    } on Object {
      // A read-only home or a full disk costs id stability across restarts,
      // not the event in hand.
    }
  }
}

/// What `analytics.json` holds, as one immutable value.
class _StoredIdentity {
  const _StoredIdentity({
    required this.pseudoId,
    required this.sessionId,
    required this.lastActive,
    required this.optedOut,
  });

  final String pseudoId;
  final String sessionId;

  /// Epoch ms of the last tracked event.
  final int lastActive;
  final bool optedOut;
}

/// A random v4 UUID — the id format both this stream and the CLI already use.
/// `Random.secure` so two machines starting in the same millisecond can't be
/// handed the same device id.
String _uuidV4(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
