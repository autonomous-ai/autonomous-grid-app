import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';
import '../../playground/logic/network_models_provider.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_configurator.dart';
import '../logic/client_app_detector.dart';
import 'app_guide_panels.dart';

/// The shared body of the "connect an app to this grid" guide: the app picker
/// plus the selected app's setup (or the raw OpenAI values for "Other app").
/// Rendered full-page by [HowToUseView]; it owns the selection + "Apply for me"
/// state. Takes the grid's real relay BASE_URL / API_KEY, pre-filled everywhere.
class AppGuideContent extends ConsumerStatefulWidget {
  const AppGuideContent({super.key, required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  @override
  ConsumerState<AppGuideContent> createState() => _AppGuideContentState();
}

class _AppGuideContentState extends ConsumerState<AppGuideContent> {
  /// The chosen app; `null` means the "Other app" tab. Ignored until [_touched]
  /// so the default can follow detection.
  ClientApp? _selected;
  bool _touched = false;
  ApplyPhase _phase = const ApplyIdle();

  void _select(ClientApp? app) => setState(() {
        _touched = true;
        _selected = app;
        _phase = const ApplyIdle();
      });

  Future<void> _apply(ClientApp app, String model) async {
    setState(() => _phase = const ApplyRunning());
    // The write is near-instant, so hold the spinner for a beat — otherwise the
    // button snaps straight to the result and the click feels like it did
    // nothing (especially on a repeat click already showing success).
    final (result, _) = await (
      ref.read(clientAppConfiguratorProvider).apply(
            app,
            widget.baseUrl,
            widget.apiKey,
            model,
          ),
      Future<void>.delayed(const Duration(milliseconds: 450)),
    ).wait;
    if (!mounted) return;
    setState(() => _phase = ApplyDone(result));
  }

  Future<void> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(installedClientAppsProvider);
    final selected = _touched
        ? _selected
        : ClientApp.values
            .firstWhere(installed.contains, orElse: () => ClientApp.openClaw);

    // Name a model the grid actually serves in every snippet/apply. Falls back
    // to the default only while the list is loading or the grid advertises none.
    final models = ref.watch(networkModelsProvider).asData?.value ?? const [];
    final model = models.isNotEmpty ? models.first : kGuideDefaultModel;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'This grid works like one AI provider. Pick the app you want to use '
          'it in — Grid can fill in the connection for you.',
          style: TextStyle(
              color: AppPalette.textSecondary, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 16),
        _AppSelector(
          selected: selected,
          installed: installed,
          onSelect: _select,
        ),
        const SizedBox(height: 18),
        if (selected == null)
          OtherAppPanel(
              baseUrl: widget.baseUrl, apiKey: widget.apiKey, model: model)
        else
          ClientAppPanel(
            info: kClientApps[selected]!,
            installed: installed.contains(selected),
            baseUrl: widget.baseUrl,
            apiKey: widget.apiKey,
            model: model,
            phase: _phase,
            onApply: () => _apply(selected, model),
            onDownload: () => _download(kClientApps[selected]!.downloadUrl),
          ),
      ],
    );
  }
}

/// The row of app choices — the two known clients (with an "Installed" dot when
/// detected) plus a generic "Other app".
class _AppSelector extends StatelessWidget {
  const _AppSelector({
    required this.selected,
    required this.installed,
    required this.onSelect,
  });

  final ClientApp? selected;
  final Set<ClientApp> installed;
  final ValueChanged<ClientApp?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final app in ClientApp.values)
          _AppChip(
            label: kClientApps[app]!.name,
            selected: selected == app,
            installed: installed.contains(app),
            onTap: () => onSelect(app),
          ),
        _AppChip(
          label: 'Other app',
          selected: selected == null,
          installed: false,
          onTap: () => onSelect(null),
        ),
      ],
    );
  }
}

/// One selectable app pill. A green dot marks an app we found installed.
class _AppChip extends StatelessWidget {
  const _AppChip({
    required this.label,
    required this.selected,
    required this.installed,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppPalette.accent.withValues(alpha: 0.16)
          : AppPalette.cardBg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? AppPalette.accent : AppPalette.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (installed) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                      color: AppPalette.online, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? AppPalette.textPrimary
                      : AppPalette.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
