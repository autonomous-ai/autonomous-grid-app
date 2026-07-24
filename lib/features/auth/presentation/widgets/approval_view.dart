import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../../../shared/layouts/onboarding_page.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/step_row.dart';
import 'browser_fallback.dart';

/// The "Finish signing in" page — shown while the browser is open and the CLI
/// polls for approval.
///
/// The wait is an inherently idle moment, so it says where the user is: three
/// steps, in the same checklist first-run setup uses, with the one they have to
/// act on marked as running. That used to be an orbiting brand seal over an
/// animated aurora, on a card, in accent — a different product from the two
/// screens either side of it.
class ApprovalView extends StatelessWidget {
  const ApprovalView({
    super.key,
    required this.url,
    required this.userCode,
    required this.onCancel,
    this.corner,
  });

  final String url;

  /// The device-flow code the browser shows too, so the user can confirm they're
  /// approving *this* machine and not a phishing prompt.
  final String userCode;
  final VoidCallback onCancel;
  final Widget? corner;

  @override
  Widget build(BuildContext context) {
    return OnboardingPage(
      title: 'Finish signing in',
      subtitle:
          'We opened Grid in your browser. Approve the request there and '
          "you'll land right back here.",
      corner: corner,
      children: [
        const StepRow(title: 'Browser opened', status: StepStatus.done),
        const StepRow(
          title: 'Approve access',
          status: StepStatus.running,
          detail: 'Waiting for you to approve it in the browser.',
        ),
        const StepRow(title: 'Connect', status: StepStatus.pending),
        if (userCode.isNotEmpty) ...[
          const SizedBox(height: 10),
          _VerifyCode(userCode: userCode),
        ],
        const SizedBox(height: 18),
        BrowserFallback(url: url),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.textSecondary,
            ),
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}

/// The "verify this code" trust cue — the same device-flow code the browser
/// shows, so the user can confirm they're approving this machine.
class _VerifyCode extends StatelessWidget {
  const _VerifyCode({required this.userCode});

  final String userCode;

  @override
  Widget build(BuildContext context) {
    // FittedBox scales the line down rather than overflowing if a long code
    // pushes the row past the column's width.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_rounded, size: 13, color: AppPalette.textSecondary),
          const SizedBox(width: 7),
          Text(
            'Verify code ',
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
          Text(
            userCode,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
              color: AppPalette.textPrimary,
            ),
          ),
          Text(
            '  ·  ${thisDeviceLabel()}',
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// "this Mac" / "this PC" / "this device" — names the machine being authorized
/// per the actual platform, so the trust cue reads true on each OS.
String thisDeviceLabel() {
  if (Platform.isMacOS) return 'this Mac';
  if (Platform.isWindows) return 'this PC';
  return 'this device';
}
