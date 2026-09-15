/// The phones paired with this computer.
///
/// Each gets its own token rather than sharing one. That is the whole point:
/// a phone that is lost, sold or stolen is revoked on its own, and the others
/// keep working — with a shared secret the only remedy is to re-pair every
/// device, which in practice means nobody revokes anything.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/grid_paths.dart';
import '../../core/owner_only_file.dart';

const _fileVersion = 1;

/// Bytes of entropy in a device token.
///
/// 24 bytes is 192 bits. The token is a bearer credential with no rate limit
/// behind it once a phone is spliced, so it has to be guess-proof on its own.
const _tokenBytes = 24;

/// One paired phone.
class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.name,
    required this.token,
    required this.pairedAtMs,
    required this.lastSeenAtMs,
  });

  /// Stable id, so a rename does not look like a new device.
  final String deviceId;

  /// What the person called it.
  final String name;

  /// This device's bearer credential. Never logged, never shown twice.
  final String token;

  /// When it was paired.
  final int pairedAtMs;

  /// When it last authenticated, or 0 if it never has.
  final int lastSeenAtMs;

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
    );
  }

  /// A copy that has just been seen.
  PairedDevice seenAt(int nowMs) => PairedDevice(
    deviceId: deviceId,
    name: name,
    token: token,
    pairedAtMs: pairedAtMs,
    lastSeenAtMs: nowMs,
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

  /// A new device with a fresh token, already persisted.
  ///
  /// The token is only returned here. It goes straight into a pairing code and
  /// is never rendered again — a credential shown twice is a credential in a
  /// screenshot.
  Future<PairedDevice> register(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final device = PairedDevice(
      deviceId: _hex(8),
      name: name,
      token: _hex(_tokenBytes),
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
/// time it, and the relay lets an attacker try from anywhere.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
