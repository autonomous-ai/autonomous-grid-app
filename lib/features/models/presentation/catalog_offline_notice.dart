import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/catalog_fallback.dart';

/// Says, where the models are listed, that the catalog couldn't be reached and
/// what's on screen is the copy this computer saved — and offers the retry.
///
/// The list stays usable behind it: everything here still downloads, because
/// `grid pull` fetches the weights from the model host, not from the catalog.
/// Silence was the alternative, and a stale ranking passed off as today's is the
/// dishonest kind of fallback.
class CatalogOfflineNotice extends StatelessWidget {
  const CatalogOfflineNotice({
    super.key,
    required this.savedAt,
    required this.onRetry,
  });

  final DateTime savedAt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final color = AppPalette.warn;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Can't reach the catalog — showing what was saved "
              '${savedAgoLabel(savedAt)}.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppPalette.textPrimary,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: color,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
