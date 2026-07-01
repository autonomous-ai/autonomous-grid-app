/// Parsed `GET {apiUrl}v1/app/version?platform=<os>` — the app-update manifest
/// the control plane serves so the desktop app can tell whether a newer build
/// exists and where to download it. Every field is null-tolerant so a partial
/// or evolving payload never throws.
///
/// Wire shape:
/// ```json
/// {
///   "version": "0.3.0",
///   "notes": "Bug fixes and speed improvements.",
///   "mandatory": false,
///   "platforms": {
///     "macos":   {"url": "https://…/Grid-0.3.0.dmg", "sha256": "…", "size": 84213456, "min_supported": "0.2.0"},
///     "windows": {"url": "https://…/Grid-0.3.0-setup.exe"},
///     "linux":   {"url": "https://…/Grid-0.3.0.AppImage"}
///   }
/// }
/// ```
class AppVersionInfo {
  const AppVersionInfo({
    required this.version,
    required this.platforms,
    this.notes,
    this.mandatory = false,
  });

  /// The latest published semantic version (e.g. `0.3.0`).
  final String version;

  /// Optional human release notes shown alongside the update prompt.
  final String? notes;

  /// Server-forced update: when true the user can't dismiss the banner.
  final bool mandatory;

  /// Download entries keyed by platform (`macos` / `windows` / `linux`).
  final Map<String, PlatformRelease> platforms;

  /// The download entry for [platformKey], or null when this platform has no
  /// published asset for [version].
  PlatformRelease? releaseFor(String platformKey) => platforms[platformKey];

  factory AppVersionInfo.fromJson(Map<String, dynamic> j) {
    final rawPlatforms = j['platforms'];
    final platforms = <String, PlatformRelease>{};
    if (rawPlatforms is Map) {
      rawPlatforms.forEach((key, value) {
        if (value is Map) {
          platforms['$key'] =
              PlatformRelease.fromJson(value.cast<String, dynamic>());
        }
      });
    }
    final notes = (j['notes'] as String?)?.trim();
    return AppVersionInfo(
      version: '${j['version'] ?? ''}'.trim(),
      notes: notes == null || notes.isEmpty ? null : notes,
      mandatory: j['mandatory'] == true,
      platforms: Map.unmodifiable(platforms),
    );
  }
}

/// One platform's downloadable build: where to get it plus optional integrity
/// metadata. [sizeBytes] seeds the download progress bar when the server omits
/// Content-Length; [minSupported] lets the server force-upgrade clients older
/// than a floor.
class PlatformRelease {
  const PlatformRelease({
    required this.url,
    this.sha256,
    this.sizeBytes,
    this.minSupported,
  });

  final String url;
  final String? sha256;
  final int? sizeBytes;
  final String? minSupported;

  /// True when there's an actual asset to download for this platform.
  bool get hasUrl => url.isNotEmpty;

  factory PlatformRelease.fromJson(Map<String, dynamic> j) => PlatformRelease(
        url: '${j['url'] ?? ''}'.trim(),
        sha256: j['sha256'] as String?,
        sizeBytes: (j['size'] as num?)?.toInt(),
        minSupported: (j['min_supported'] as String?)?.trim(),
      );
}
