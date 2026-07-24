import 'package:flutter/material.dart';

import '../../../../shared/external_launch.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';

/// Shared visual chrome for the inline media widgets, so image, video and audio
/// share one frame, one loading state and one failure state.

const double kMediaMaxHeight = 320;
final BorderRadius kMediaRadius = BorderRadius.circular(10);

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
        child: const Center(child: AppSpinner(size: SpinnerSize.large)),
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
