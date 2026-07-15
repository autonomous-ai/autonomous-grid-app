import 'package:flutter/material.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import 'media/media_chrome.dart';

/// The web pages an agent turn cited, shown as clickable chips — live in the
/// working bubble and pinned under the finished answer. Clicking one opens it in
/// the browser, so a reply built from the web is traceable to where it came
/// from. Renders nothing when there are no sources.
class MessageSources extends StatelessWidget {
  const MessageSources({super.key, required this.sources});

  final List<WebSource> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public, size: 13, color: AppPalette.textSecondary),
            const SizedBox(width: 6),
            Text(
              _label(sources.length),
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final source in sources) _SourceChip(source: source)],
        ),
      ],
    );
  }

  static String _label(int count) => count == 1 ? '1 source' : '$count sources';
}

/// One source: its title over its host, opening the page on tap.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final WebSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: source.url,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => openExternalUrl(source.url),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.open_in_new_rounded,
                  size: 13,
                  color: AppPalette.textFaint,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (source.host.isNotEmpty)
                        Text(
                          source.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppPalette.textFaint,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
