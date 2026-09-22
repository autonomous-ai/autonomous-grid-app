/// Telling the phones where this computer is, and nothing else.
///
/// One write per phone per address, and an address changes when the tunnel does
/// — a few times a day at worst. That budget is the whole reason the locator can
/// live on a free tier shared with other apps, so the guard against writing the
/// same address twice is not a micro-optimisation: it is the thing keeping this
/// inside its means.
///
/// **A failure here is not a failure to share.** The cell is already listening
/// and a phone that still holds a good address connects fine; what a failed
/// publish costs is a phone that comes back *later* not finding the new one. So
/// every failure is logged and reported to the screen, and none of them stops
/// the computer from serving.
library;

import 'package:grid_pairing/grid_pairing.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/pairing_host/device_registry.dart';

/// Publishes this computer's address for the phones that hold a code for it.
class PhoneLocatorPublisher {
  PhoneLocatorPublisher({required LocatorClient client, required AppLog log})
    : _client = client,
      _log = log;

  final LocatorClient _client;
  final AppLog _log;

  /// The address last published under each code, so an unchanged one is not
  /// written again.
  final _published = <String, String>{};

  /// Publishes [record] for every phone in [devices].
  ///
  /// Returns what to tell the person, or null when there is nothing to say.
  /// One sentence for all of them rather than one per phone: three phones on a
  /// machine that is offline is one problem, and saying it three times reads as
  /// three.
  Future<String?> publishAll(
    List<PairedDevice> devices,
    LocatorRecord record,
  ) async {
    LocatorFailure? worst;
    for (final device in devices) {
      final failure = await publish(device, record);
      if (failure != null) worst = failure;
    }
    return worst?.message;
  }

  /// Publishes [record] for one phone, or skips it when that phone already
  /// holds this address.
  Future<LocatorFailure?> publish(
    PairedDevice device,
    LocatorRecord record,
  ) async {
    final token = PairToken.tryParse(device.token);
    if (token == null) {
      _log.warn('phone', 'no usable code stored for ${device.deviceId}');
      return null;
    }
    if (_published[device.token] == record.cellUrl) return null;
    final failure = await _client.publish(token, record);
    if (failure != null) {
      // Logged as well as returned. A sentence the user just read is not a
      // diagnosis, and this is the layer that knows which phone it was.
      _log.warn(
        'phone',
        'could not publish the address for ${device.name}: ${failure.message}',
      );
      return failure;
    }
    _published[device.token] = record.cellUrl;
    _log.info('phone', 'published this computer\'s address for ${device.name}');
    return null;
  }

  /// Forgets what [device] was told, so a revoked phone finds nothing.
  ///
  /// Best effort: the phone is already refused at the channel, and a locator
  /// that could not be tidied up must not leave a revoke half done.
  Future<void> erase(PairedDevice device) async {
    _published.remove(device.token);
    final token = PairToken.tryParse(device.token);
    if (token == null) return;
    final failure = await _client.erase(token);
    if (failure == null) return;
    _log.warn(
      'phone',
      'could not erase the address for ${device.name}: ${failure.message}',
    );
  }

  /// Forgets every address published in this session, so the next publish
  /// writes even if the tunnel came back at the same place.
  void forget() => _published.clear();
}
