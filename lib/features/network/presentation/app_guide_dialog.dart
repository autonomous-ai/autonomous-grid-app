import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import 'app_guide_content.dart';

/// Popup version of the connect-an-app guide, opened from the grid detail's
/// "How to use" button. The full-page version is [HowToUseView]; both render the
/// same [AppGuideContent]. Takes the grid's real relay BASE_URL / API_KEY.
class AppGuideDialog extends StatelessWidget {
  const AppGuideDialog({super.key, required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppPalette.panelBg,
      title: const Text('Connect an app to this grid'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          child: AppGuideContent(baseUrl: baseUrl, apiKey: apiKey),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
