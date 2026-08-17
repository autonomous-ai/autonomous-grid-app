import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_log.dart';
import 'panel_firmware.dart';

/// Where the panel firmware rides along in the app bundle.
///
/// A copy, not a reference into a device's build tree: an ESP-IDF build tree is
/// tens of thousands of gitignored files, so an asset line pointing into one
/// would fail the Flutter build on every machine that has not built the
/// firmware — which is most of them.
///
/// No device lives in this repo today (`assets/panel/README.md` says what to
/// drop here). The image states its own version, so nothing has to be kept in
/// step with whatever gets built next.
const String kPanelFirmwareAsset = 'assets/panel/grid_panel.bin';

/// The firmware image this build carries, or null when it carries none.
///
/// Null rather than an error, and the app simply never offers an update: a
/// checkout with no panel firmware in it is the normal state — the asset
/// directory ships empty — and it must not be a reason the handshake fails.
///
/// A future, and read once per session, because it is a megabyte off disk. The
/// bytes stay resident afterwards — the same panel usually gets plugged in
/// again, and re-reading them per `hello` would be a megabyte per cable nudge.
final panelFirmwareProvider = FutureProvider<PanelFirmwareImage?>((ref) async {
  final log = ref.read(appLogProvider);
  final ByteData data;
  try {
    data = await rootBundle.load(kPanelFirmwareAsset);
  } on Object catch (e) {
    log.info('panel', 'No panel firmware is bundled with this build: $e');
    return null;
  }
  final image = PanelFirmwareImage.read(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  if (image == null) {
    // Loud, because the bytes are there and unreadable: something copied a
    // partial image, or copied the wrong file entirely.
    log.warn(
      'panel',
      '$kPanelFirmwareAsset is ${data.lengthInBytes} bytes but not an ESP-IDF '
          'image — no update can be offered from it',
    );
    return null;
  }
  log.info(
    'panel',
    'This build carries panel firmware ${image.version} '
        '(${image.size} bytes, sha256 ${image.sha256})',
  );
  return image;
});
