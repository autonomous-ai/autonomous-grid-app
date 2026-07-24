import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/choice_row.dart';
import '../../../network/presentation/detail_widgets.dart';

/// The "Browser didn't open?" fallback, worn as one of the app's choice rows.
///
/// Same shape as an option on the choose-a-model screen, because it is one: a
/// title, a line, and a chevron that opens what it promises. Collapsed by
/// default — the browser has usually opened already; this is the way out when it
/// didn't.
class BrowserFallback extends StatefulWidget {
  const BrowserFallback({super.key, required this.url});

  final String url;

  @override
  State<BrowserFallback> createState() => _BrowserFallbackState();
}

class _BrowserFallbackState extends State<BrowserFallback> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return ChoiceRowGroup(
      outlined: true,
      children: [
        ChoiceRow(
          icon: const Icon(Icons.open_in_new_rounded),
          title: "Browser didn't open?",
          line: 'Open the sign-in link by hand.',
          action: ChoiceRowAction.open,
          expanded: _open,
          onPressed: () => setState(() => _open = !_open),
          child: _open ? _FallbackBody(url: widget.url) : null,
        ),
      ],
    );
  }
}

/// What the row opens: the link to copy, and the raw URL in a mono chip — so a
/// user whose browser stayed shut can get the link out by hand and see exactly
/// what they'd be opening.
class _FallbackBody extends StatelessWidget {
  const _FallbackBody({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Aligned under the row's title, not its icon gutter.
      padding: const EdgeInsets.fromLTRB(47, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: () =>
                copyToClipboard(context, url, message: 'Link copied.'),
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('Copy sign-in link'),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppCard.inset,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppCard.insetHair),
            ),
            child: SelectableText(
              url,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
