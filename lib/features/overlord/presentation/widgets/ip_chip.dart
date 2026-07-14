import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/theme/app_theme.dart';
import '../overlord_tokens.dart';

/// A boxed, monospace endpoint with a copy affordance — the `192.168.50.134:8000`
/// chip on a serving GPU. Tap to copy to the clipboard.
class IpChip extends StatelessWidget {
  const IpChip({super.key, required this.endpoint});

  final String endpoint;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.cardBg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _copy(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 3, 5, 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppPalette.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  endpoint,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: OverlordTokens.mono,
                    fontSize: 11.5,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.copy_outlined,
                  size: 11, color: AppPalette.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: endpoint));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $endpoint'),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}
