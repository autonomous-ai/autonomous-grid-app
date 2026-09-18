/// What the type settings actually look like.
///
/// Both faces at once, because the point of the pair is how they sit together:
/// a line of prose over a block of code, which is the shape of every answer this
/// app shows. The code half wears the real code size, out of the UI scale, so
/// the two settings read as the independent things they are.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import 'parts.dart';

/// A specimen of the app's own prose and code.
class AppearancePreview extends StatelessWidget {
  const AppearancePreview({super.key});

  @override
  Widget build(BuildContext context) {
    // The one line that makes this follow a size change: AppFont is a static,
    // and [AppTheme.watch] registers for the type signal as well as the palette
    // — so nothing here needs to watch the provider a second time.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppPalette.textFaint,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Here is how a reply reads, and the code inside one:',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          // The same rule the chat's own code blocks follow, so what is shown
          // here is what a reply will be — a preview drawn its own way is a
          // preview that can disagree with the thing it previews.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppCard.inset,
              borderRadius: BorderRadius.circular(AppCard.insetRadius),
              border: Border.all(color: AppCard.insetHair),
            ),
            child: Text(
              _sample,
              style: TextStyle(
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                fontSize: AppFont.codeSizeDescaled,
                height: 1.45,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Chosen to exercise what a code face is judged on rather than to do
  /// anything useful: `0O` and `1lI` adjacent, so a slashed zero and a tailed
  /// `l` are visible or their absence is, plus the bracket trio and the arrow.
  static const _sample =
      'def fetch(urls: list[str]) -> dict:\n'
      '    # 0O 1lI — the zero, the one, the ell\n'
      '    return {"data": get(urls[0])}';
}
