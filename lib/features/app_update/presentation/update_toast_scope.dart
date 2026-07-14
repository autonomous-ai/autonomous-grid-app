import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_environment.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/app_updater_service.dart';

/// Toasts the outcome of every update check, wherever it was started from — the
/// macOS "Grid ▸ Check for Updates…" app menu or the in-app account menu.
///
/// It wraps the whole app rather than living in the title bar because the app
/// menu is reachable on the login screen too, where the title bar isn't built:
/// without a listener mounted there, a tap on the menu item resolved to silence.
class UpdateToastScope extends ConsumerStatefulWidget {
  const UpdateToastScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<UpdateToastScope> createState() => _UpdateToastScopeState();
}

class _UpdateToastScopeState extends ConsumerState<UpdateToastScope> {
  OverlayEntry? _entry;
  Timer? _dismissTimer;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appUpdateStatusProvider, (_, next) {
      final status = next.asData?.value;
      if (status != null) _show(status);
    });
    return widget.child;
  }

  void _show(UpdateStatus status) {
    _dismissTimer?.cancel();
    _entry?.remove();

    final overlay = Overlay.of(context);
    final toast = _UpdateToast(
      status: status,
      onClose: _hide,
      onDownload: () => launchUrl(
        Uri.parse(AppEnvironment.websiteUrl),
        mode: LaunchMode.externalApplication,
      ),
    );
    _entry = OverlayEntry(builder: (_) => toast);
    overlay.insert(_entry!);

    _dismissTimer = Timer(const Duration(seconds: 4), _hide);
  }

  void _hide() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _UpdateToast extends StatelessWidget {
  const _UpdateToast({
    required this.status,
    required this.onClose,
    required this.onDownload,
  });

  final UpdateStatus status;
  final VoidCallback onClose;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final details = _details(context, status);
    return Positioned(
      top: 18,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: false,
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 18),
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: -8, end: 0),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              builder: (context, dy, child) =>
                  Transform.translate(offset: Offset(0, dy), child: child),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: AppPalette.divider),
                      boxShadow: AppGlass.shadow,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StatusIcon(details: details),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              details.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (status is UpdateUnsupported) ...[
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: onDownload,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 30),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text('Download'),
                            ),
                          ],
                          const SizedBox(width: 2),
                          IconButton(
                            tooltip: 'Dismiss',
                            onPressed: onClose,
                            iconSize: 16,
                            visualDensity: VisualDensity.compact,
                            color: AppPalette.textFaint,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  _ToastDetails _details(BuildContext context, UpdateStatus status) =>
      switch (status) {
        UpdateChecking() => const _ToastDetails(
          icon: Icons.sync_rounded,
          color: AppPalette.accent,
          message: 'Checking for updates...',
        ),
        UpdateUpToDate() => _ToastDetails(
          icon: Icons.check_circle_outline_rounded,
          color: AppPalette.online,
          message: "You're on the latest version.",
        ),
        UpdateAvailable(:final version) => _ToastDetails(
          icon: Icons.system_update_alt_rounded,
          color: AppPalette.accent,
          message: version == null
              ? 'An update is available. Follow the prompt to install.'
              : 'Update available: $version. Follow the prompt to install.',
        ),
        UpdateFailed(:final message) => _ToastDetails(
          icon: Icons.error_outline_rounded,
          color: Theme.of(context).colorScheme.error,
          message: "Couldn't check for updates: $message",
        ),
        UpdateUnsupported() => _ToastDetails(
          icon: Icons.open_in_new_rounded,
          color: AppPalette.warn,
          message: "This copy of Grid can't update itself.",
        ),
      };
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.details});

  final _ToastDetails details;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: details.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(details.icon, size: 16, color: details.color),
    );
  }
}

class _ToastDetails {
  const _ToastDetails({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;
}
