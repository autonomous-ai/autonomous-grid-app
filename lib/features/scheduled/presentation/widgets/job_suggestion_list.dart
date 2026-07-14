import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/job_suggestions.dart';
import 'new_job_dialog.dart';

/// The three ready-made tasks a blank Scheduled screen offers. Tapping one opens
/// the New task dialog already filled in, so the first task is a click and an
/// edit — not a blank form.
class JobSuggestionList extends StatelessWidget {
  const JobSuggestionList({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Ideas',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textFaint,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        for (final suggestion in kJobSuggestions)
          _SuggestionRow(suggestion: suggestion),
      ],
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion});

  final JobSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(10);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => showNewJobDialog(context, from: suggestion),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.notifications_none_rounded,
                    size: 17,
                    color: AppPalette.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              suggestion.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            suggestion.schedule.describe(),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppPalette.textFaint,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        suggestion.prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textSecondary,
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
