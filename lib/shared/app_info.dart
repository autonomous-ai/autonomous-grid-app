import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The app's semantic version (e.g. `0.2.0`), read from the platform bundle.
/// CI stamps this from the release tag at build time (`set-version.sh`), so it
/// always matches the published version. Loaded once and cached for the session.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});
