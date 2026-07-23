import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_configurator.dart';
import '../logic/client_app_detector.dart';
import '../logic/grid_overview_provider.dart';
import 'app_guide_panels.dart';

/// The shared body of the "connect an app to this grid" guide: the app picker
/// plus the selected app's setup (or the raw OpenAI values for "Other app").
/// Rendered full-page by [HowToUseView]; it owns the selection + "Apply for me"
/// state. Takes the grid's real relay BASE_URL / API_KEY, pre-filled everywhere.
class AppGuideContent extends ConsumerStatefulWidget {
  const AppGuideContent({
    super.key,
    required this.baseUrl,
    required this.apiKey,
  });

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

  /// Lifecycle of the one-click "Set up for me" write for the selected app.
  /// Reset whenever the app changes so one grid's result never lingers on
  /// another's panel.
  ApplyPhase _phase = const ApplyIdle();

  void _select(ClientApp? app) => setState(() {
    _touched = true;
    _selected = app;
    _phase = const ApplyIdle();
  });

  /// Writes the grid's connection into the selected client's config
  /// (`~/.hermes/config.yaml` / `~/.openclaw/openclaw.json`) via
  /// [ClientAppConfigurator]. Only reached for chat grids, where the grid can be
  /// the client's model. Holds the spinner briefly so a near-instant write still
  /// reads as an action.
  Future<void> _apply(ClientApp app, List<String> models) async {
    setState(() => _phase = const ApplyRunning());
    final (result, _) = await (
      ref
          .read(clientAppConfiguratorProvider)
          .apply(app, widget.baseUrl, widget.apiKey, models),
      Future<void>.delayed(const Duration(milliseconds: 450)),
    ).wait;
    if (!mounted) return;
    setState(() => _phase = ApplyDone(result));
  }

  Future<void> _openSite(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final installed = ref.watch(installedClientAppsProvider);
    // Until the user picks: the first app they already have, else the first the
    // build offers. Both come off [kSelectableClientApps], so a hidden app can
    // never land here as the default and draw a panel with no tab to match it.
    final selected = _touched
        ? _selected
        : kSelectableClientApps.firstWhere(
            installed.contains,
            orElse: () => kSelectableClientApps.first,
          );

    // Every chat model the grid serves — OpenClaw lists them all; the first is
    // the default named in single-model snippets/apply. Falls back to the
    // default id only while the list loads or the grid advertises none, so a
    // snippet is never empty.
    final chatIds = ref.watch(gridChatModelIdsProvider);
    final models = chatIds.isEmpty ? const [kGuideDefaultModel] : chatIds;
    final model = models.first;

    // Media grids (image/video) can't be wired as a chat provider — the panels
    // swap the chat setup for a "build a skill" prompt / media API call. `hasChat`
    // stays the default while the overview loads (media resolves to none), so a
    // chat grid never flashes empty first.
    final media = ref.watch(gridMediaCapabilitiesProvider);
    final hasChat = ref.watch(gridHasChatProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'This grid works like one AI provider. Pick the app you want to use '
          'it in — Grid can fill in the connection for you.',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 13,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 16),
        _AppSelector(
          selected: selected,
          installed: installed,
          onSelect: _select,
        ),
        // 16, not 18 — the vertical rhythm stays on the 4pt scale.
        const SizedBox(height: 16),
        if (selected == null)
          OtherAppPanel(
            baseUrl: widget.baseUrl,
            apiKey: widget.apiKey,
            model: model,
            media: media,
            hasChat: hasChat,
          )
        else
          ClientAppPanel(
            info: kClientApps[selected]!,
            installed: installed.contains(selected),
            baseUrl: widget.baseUrl,
            apiKey: widget.apiKey,
            models: models,
            media: media,
            hasChat: hasChat,
            phase: _phase,
            onApply: () => _apply(selected, models),
            onOpenSite: () => _openSite(kClientApps[selected]!.downloadUrl),
          ),
      ],
    );
  }
}

/// The row of app choices — every client this build offers (with an "Installed"
/// dot when detected) plus a generic "Other app". Which clients those are is
/// [ClientAppX.isSelectable]'s call, never this widget's.
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
        for (final app in kSelectableClientApps)
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
///
/// Built on the shared [PillChoice] rather than a hand-rolled bordered chip:
/// the old version drew a `Border` for both states (against the no-borders
/// rule) and marked selection with colour alone. Selection now reads three
/// ways — accent fill, white label, and the lift `PillChoice` gives it.
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
    // Reads AppPalette.online below and is rebuilt only when the selection
    // changes, so it needs its own watch to survive a theme flip.
    AppTheme.watch(context);
    return PillChoice(
      selected: selected,
      onTap: onTap,
      height: AppControl.height,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (installed) ...[
            // White on the accent fill so the "installed" mark stays visible
            // once the pill is selected — `online` green on accent is muddy.
            StatusDot(
              color: selected ? Colors.white : AppPalette.online,
              size: 6,
            ),
            const SizedBox(width: 7),
          ],
          Text(label),
        ],
      ),
    );
  }
}
