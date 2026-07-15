import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../shared/theme/app_theme.dart';

/// Shared visual chrome for the inline media widgets, so image, video and audio
/// share one frame, one loading state and one failure state.

const double kMediaMaxHeight = 320;
final BorderRadius kMediaRadius = BorderRadius.circular(10);

/// Open [url] in the user's browser / default handler. Best-effort.
///
/// A local file path (`/Users/…/x.png`) or a schemeless value is opened as a
/// `file://` URI — otherwise the OS has no handler and refuses it (macOS error
/// -50), which is exactly what a bare path used to hit.
Future<void> openExternalUrl(String url) async {
  final uri = _launchableUri(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Uri? _launchableUri(String url) {
  if (url.startsWith('/')) return Uri.file(url);
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  return uri.hasScheme ? uri : Uri.file(url);
}

/// `m:ss` (or `h:mm:ss`) for player timestamps; `--:--` while unknown.
String formatMediaDuration(Duration d) {
  if (d <= Duration.zero) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}

/// Rounded, bordered frame every media segment sits in.
class MediaFrame extends StatelessWidget {
  const MediaFrame({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: kMediaRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.windowBg,
          borderRadius: kMediaRadius,
          border: Border.all(color: AppPalette.divider),
        ),
        child: padding == null
            ? child
            : Padding(padding: padding!, child: child),
      ),
    );
  }
}

/// Square-ish placeholder shown while a media resource is loading.
class MediaLoadingBox extends StatelessWidget {
  const MediaLoadingBox({super.key, this.height = 160});
  final double height;

  @override
  Widget build(BuildContext context) {
    return MediaFrame(
      child: SizedBox(
        height: height,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

/// Fallback when a media resource can't be displayed — names the failure and
/// offers to open the source externally.
class MediaErrorBox extends StatelessWidget {
  const MediaErrorBox({
    super.key,
    required this.url,
    required this.icon,
    required this.label,
  });

  final String url;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MediaFrame(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => openExternalUrl(url),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}
