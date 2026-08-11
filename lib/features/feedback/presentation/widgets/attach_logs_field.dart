import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/log_bundle.dart';

/// The "attach diagnostic logs" control: a switch, and — one tap away — the
/// exact text that would be uploaded.
///
/// This is the one attachment that isn't machine metadata. Today's app logs
/// carry file paths and the output of the commands the app ran, so the switch
/// is *shown* (never silent) and its contents are readable before the send.
/// It defaults on because a report with the logs is worth far more, and secrets
/// are stripped ([redactLogSecrets]) — but the person always gets to look and
/// to say no.
///
/// Dressed as the form's last field: the same recessed fill and radius as the
/// message box, so it reads as one more row rather than a separate object.
class AttachLogsField extends ConsumerStatefulWidget {
  const AttachLogsField({
    super.key,
    required this.attached,
    required this.onChanged,
    this.enabled = true,
  });

  final bool attached;
  final ValueChanged<bool> onChanged;

  /// False while a send is in flight — the whole form locks together.
  final bool enabled;

  @override
  ConsumerState<AttachLogsField> createState() => _AttachLogsFieldState();
}

class _AttachLogsFieldState extends ConsumerState<AttachLogsField> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppCard/AppPalette tokens inside a dialog — watch, or it keeps the
    // palette it was first built with across a theme flip.
    AppTheme.watch(context);
    final bundle = ref.watch(feedbackLogBundleProvider).asData?.value;
    return DecoratedBox(
      decoration: BoxDecoration(
        // The field family's surface: recessed against the dialog in dark, where
        // `cardBg` lands within 1.02:1 of it; `cardBg` in light, where the recess
        // is the one that disappears against white.
        color: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              attached: widget.attached,
              enabled: widget.enabled,
              summary: _summary(bundle),
              onChanged: widget.onChanged,
            ),
            if (widget.attached && (bundle?.isEmpty ?? true) == false) ...[
              const SizedBox(height: 4),
              _Disclosure(
                expanded: _expanded,
                onTap: () => setState(() => _expanded = !_expanded),
              ),
              AnimatedSize(
                duration: AppMotion.swap,
                curve: AppMotion.curve,
                alignment: Alignment.topLeft,
                child: _expanded
                    ? _Preview(bundle: bundle!)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The sub-line under the toggle: how many files, how big — or that there's
  /// nothing to attach today.
  String _summary(FeedbackLogBundle? bundle) {
    if (bundle == null) return 'Gathering…';
    if (bundle.isEmpty) return 'No logs recorded today — nothing to attach.';
    final kb = (bundle.totalBytes / 1024).ceil();
    final n = bundle.files.length;
    return "Today's ${n == 1 ? 'log' : '$n logs'} (~$kb KB). "
        'Includes file paths and command output — secrets removed.';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.attached,
    required this.enabled,
    required this.summary,
    required this.onChanged,
  });

  final bool attached;
  final bool enabled;
  final String summary;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attach diagnostic logs',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFont.medium,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                summary,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(value: attached, onChanged: enabled ? onChanged : null),
      ],
    );
  }
}

/// The "see what's included" line — a text affordance, quieter than a button.
class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppControl.radius),
        hoverColor: AppSurface.hoverFill,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 16,
                color: AppPalette.accentOnSurface,
              ),
              const SizedBox(width: 4),
              Text(
                expanded ? 'Hide what gets sent' : 'See what gets sent',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: AppFont.medium,
                  color: AppPalette.accentOnSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bundle's contents, readable: each file named, then its redacted text in a
/// scrollable mono box. What the user reads here is byte-for-byte what the zip
/// carries — same [BundledLog.text] the encoder consumes.
class _Preview extends StatelessWidget {
  const _Preview({required this.bundle});

  final FeedbackLogBundle bundle;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 0, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final file in bundle.files) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${file.name} · ${(file.bytes / 1024).ceil()} KB',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFont.medium,
                  color: AppPalette.textFaint,
                ),
              ),
            ),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 150),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.isDark ? AppPalette.panelBg : AppCard.inset,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  file.text,
                  style: TextStyle(
                    fontFamily: AppFont.mono,
                    fontSize: 11,
                    height: 1.4,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
