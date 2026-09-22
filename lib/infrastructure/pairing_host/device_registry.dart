/// The phones paired with this computer.
///
/// Each gets its own connect code rather than sharing one. That is the whole
/// point: a phone that is lost, sold or stolen is revoked on its own, and the
/// others keep working — with one code for the computer the only remedy is to
/// change it, which means re-entering it on every phone, which means nobody
/// ever revokes anything.
///
/// The code doubles as the name of that phone's locator document, so revoking
/// here has a second half: the record is erased too, and the phone finds
/// nothing rather than an address it can no longer use.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:grid_pairing/grid_pairing.dart';

import '../../core/grid_paths.dart';
import '../../core/owner_only_file.dart';

const _fileVersion = 1;

/// One paired phone.
class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.name,
    required this.token,
    required this.pairedAtMs,
    required this.lastSeenAtMs,
    this.mayAct = false,
  });

  /// Stable id, so a rename does not look like a new device.
  final String deviceId;

  /// What the person called it.
  final String name;

  /// The connect code this phone was given, normalised.
  ///
  /// It is a bearer credential for this computer and it is also the thing a
  /// person reads off the screen, so it is shown deliberately rather than
  /// never: losing it would otherwise mean revoking a phone that works. It is
  /// still never logged.
  final String token;

  /// When it was paired.
  final int pairedAtMs;

  /// When it last authenticated, or 0 if it never has.
  final int lastSeenAtMs;

  /// Whether this phone may make the computer *do* something, rather than only
  /// read what it has already done.
  ///
  /// **Default false, and it stays false until a person turns it on for this
  /// one device, at the computer.** Reading a chat is a phone that knows what
  /// happened; sending one is a phone that starts an agent with this machine's
  /// filesystem and keys behind it. A phone is a thing somebody can pick up, so
  /// that second power is not something a code should hand out — a code proves
  /// which device, not what the person holding it may do.
  final bool mayAct;

  /// Whether this device has ever completed a connection.
  ///
  /// A code that was generated and never scanned leaves one of these behind;
  /// it is the only kind safe to drop without asking anyone.
  bool get everConnected => lastSeenAtMs > 0;

  /// This device as stored JSON.
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'token': token,
    'pairedAt': pairedAtMs,
    'lastSeenAt': lastSeenAtMs,
    'mayAct': mayAct,
  };

  /// The device [value] describes, or null when the record is unusable.
  static PairedDevice? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final deviceId = value['deviceId'];
    final name = value['name'];
    final token = value['token'];
    if (deviceId is! String || name is! String || token is! String) return null;
    return PairedDevice(
      deviceId: deviceId,
      name: name,
      token: token,
      pairedAtMs: value['pairedAt'] is int ? value['pairedAt']! as int : 0,
      lastSeenAtMs: value['lastSeenAt'] is int
          ? value['lastSeenAt']! as int
          : 0,
      // Anything but a stored `true` is false, so a registry written by a build
      // that predates this field grants nothing.
      mayAct: value['mayAct'] == true,
    );
  }

  /// A copy that has just been seen.
  PairedDevice seenAt(int nowMs) => _with(lastSeenAtMs: nowMs);

  /// A copy allowed — or no longer allowed — to make this computer act.
  PairedDevice actingAllowed(bool allowed) => _with(mayAct: allowed);

  PairedDevice _with({int? lastSeenAtMs, bool? mayAct}) => PairedDevice(
    deviceId: deviceId,
    name: name,
    token: token,
    pairedAtMs: pairedAtMs,
    lastSeenAtMs: lastSeenAtMs ?? this.lastSeenAtMs,
    mayAct: mayAct ?? this.mayAct,
  );
}

/// The paired-device file, read and written whole.
///
/// Whole-file because the list is a handful of entries and the alternative —
/// partial updates to a secret file — is how you end up with a half-written
/// registry that locks every phone out at once.
class DeviceRegistry {
  DeviceRegistry({Random? random, File? file})
    : _random = random ?? Random.secure(),
      _file = file ?? GridPaths.pairedDevicesFile;

  final Random _random;
  final File _file;

  /// Every paired device, oldest first.
  Future<List<PairedDevice>> load() async {
    if (!_file.existsSync()) return const [];
    final Object? value;
    try {
      value = jsonDecode(await _file.readAsString());
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
    if (value is! Map<String, Object?> || value['v'] != _fileVersion) {
      return const [];
    }
    final devices = value['devices'];
    if (devices is! List) return const [];
    return [for (final entry in devices) ?PairedDevice.fromJson(entry)];
  }

  /// A new device holding [token], already persisted.
  ///
  /// The token is minted by the caller rather than here because it is not only
  /// a credential: it also names the locator document this computer publishes
  /// its address to, and the two have to be the same value or the phone reads
  /// an address it cannot then authenticate against ([PairToken]).
  Future<PairedDevice> register(String name, PairToken token) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final device = PairedDevice(
      deviceId: _hex(8),
      name: name,
      token: token.normalized,
      pairedAtMs: now,
      lastSeenAtMs: 0,
    );
    await _save([...await load(), device]);
    return device;
  }

  /// The device [token] belongs to, or null when nothing does.
  Future<PairedDevice?> authenticate(String token) async {
    for (final device in await load()) {
      if (_constantTimeEquals(device.token, token)) return device;
    }
    return null;
  }

  /// Records that [deviceId] just connected.
  Future<void> markSeen(String deviceId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final devices = await load();
    if (!devices.any((device) => device.deviceId == deviceId)) return;
    await _save([
      for (final device in devices)
        device.deviceId == deviceId ? device.seenAt(now) : device,
    ]);
  }

  /// Lets [deviceId] send messages to the agents, or stops it.
  ///
  /// Takes effect on the phone's next call: the flag is read per request rather
  /// than held for the life of a session, so turning this off reaches a phone
  /// that is connected right now instead of the next time it dials in.
  Future<void> setMayAct(String deviceId, bool allowed) async {
    final devices = await load();
    if (!devices.any((device) => device.deviceId == deviceId)) return;
    await _save([
      for (final device in devices)
        device.deviceId == deviceId ? device.actingAllowed(allowed) : device,
    ]);
  }

  /// Drops [deviceId]. The phone's next request fails and it must pair again.
  Future<void> revoke(String deviceId) async {
    final devices = await load();
    await _save(devices.where((d) => d.deviceId != deviceId).toList());
  }

  Future<void> _save(List<PairedDevice> devices) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'v': _fileVersion,
        'devices': [for (final device in devices) device.toJson()],
      }),
    );
    await restrictToOwner(_file);
  }

  String _hex(int bytes) => [
    for (var i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Compares in time that does not depend on how far in the two differ.
///
/// A token comparison that returns early leaks its prefix to anyone who can
/// time it, and the address this computer answers on is a public one.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
