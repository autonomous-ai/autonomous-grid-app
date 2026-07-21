import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';

/// A one-line note + Download button shown when the client isn't installed yet.
class MissingAppNote extends StatelessWidget {
  const MissingAppNote({
    super.key,
    required this.name,
    required this.onDownload,
  });

  final String name;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "You don't have $name yet. Install it first, then paste the "
            'connection below.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text('Download $name'),
          ),
        ],
      ),
    );
  }
}

/// Shown on a media-only grid: the agent needs its own chat model to run and
/// build the skill, and this grid (images/video) can't be that model. Names the
/// next step so the user isn't stuck on "No inference provider configured".
class NeedsChatModelNote extends StatelessWidget {
  const NeedsChatModelNote({
    super.key,
    required this.appName,
    required this.command,
  });

  final String appName;
  final String command;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      child: Text(
        '$appName needs its own chat model to run and build this skill. This '
        "grid only makes images or video, so it can't be that model — set one "
        'up first (run `$command model`, or add a provider API key in $appName), '
        'then paste the prompt below.',
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 12.5,
          height: 1.4,
        ),
      ),
    );
  }
}
