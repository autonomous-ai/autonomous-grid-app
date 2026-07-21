import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/engine_slots.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'engine_block.dart';
import 'engine_cost_chip.dart';

/// The "Cloud Provider" engine block: serve a hosted model (e.g. OpenAI's) to
/// the grid using the user's own API key, with no local engine, model download,
/// or setup.
///
/// Hidden entirely when no hosted provider is available — either `grid` is
/// missing or the installed CLI whitelists none we can present ([apiEnginesProvider]).
/// The block never appears for a provider a `grid join --api` would reject.
class ApiEngineBlock extends ConsumerWidget {
  const ApiEngineBlock({
    super.key,
    required this.network,
    this.compact = false,
    this.headerless = false,
  });

  final NetworkCredential network;

  /// Drop the block's own icon/title/subtitle — see [EngineBlock.headerless].
  /// Set by the Model Engines page, where the add-engine picker above already
  /// names this path. Onboarding leaves it off: there the block stands alone.
  final bool headerless;

  /// Trims the secondary copy (the model-freshness line) for a first-run
  /// context like onboarding, where the full form reads as a wall of text next
  /// to the other one-line options. The Model Engines screen keeps the full
  /// detail (`compact: false`).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = ref.watch(apiEnginesProvider);
    // An optional path: while probing, or if no provider resolves / the catalog
    // read fails, we simply don't show the block rather than a broken shell.
    final available = engines.asData?.value ?? const <ApiEngine>[];
    if (available.isEmpty) return const SizedBox.shrink();

    // Only claim "or your ChatGPT subscription" when a sign-in provider is
    // actually available on this CLI — otherwise the subtitle over-promises.
    final hasSignIn = available.any((e) => e.provider.usesSignIn);
    // A hosted model this machine already serves can't be shared again — the
    // grid would be offered the same name twice. The form takes them out of
    // play rather than letting a second join fail or shadow the first.
    final alreadyShared = apiModelsServed(ref.watch(servingEnginesProvider));
    return EngineBlock(
      // Under the add-engine picker the pill and its hint already name this
      // path; the header would say "Cloud" a third and fourth time.
      headerless: headerless,
      icon: Icons.cloud_outlined,
      title: 'Cloud Provider',
      // Every hosted engine spends the user's own vendor account per request —
      // the one thing about this block worth knowing before filling it in.
      trailing: const EngineCostChip(cost: EngineCost.metered),
      subtitle: hasSignIn
          ? 'Your own API key or ChatGPT subscription — no model download.'
          : 'A hosted provider with your own API key — no model download.',
      child: ApiEngineForm(
        network: network,
        engines: available,
        alreadyShared: alreadyShared,
        compact: compact,
      ),
    );
  }
}

/// Pick a provider (when more than one is available), paste an API key, choose
/// which models to share, and start. The key travels to the CLI via the
/// environment (never argv), and a key the CLI already saved lets the user start
/// again without re-pasting.
///
/// Public because onboarding presents the same form under its own cards — one
/// per way in (a ChatGPT subscription, a pasted key) — instead of the single
/// "Cloud Provider" block with a provider dropdown that this screen uses. Hand
/// it the [engines] that card is about; with one, it drops the dropdown.
class ApiEngineForm extends ConsumerStatefulWidget {
  const ApiEngineForm({
    super.key,
    required this.network,
    required this.engines,
    required this.alreadyShared,
    required this.compact,
  });

  final NetworkCredential network;
  final List<ApiEngine> engines;

  /// Advertised names this machine already serves from a hosted provider — off
  /// the table, so the same model can't be shared twice.
  final Set<String> alreadyShared;
  final bool compact;

  @override
  ConsumerState<ApiEngineForm> createState() => _ApiEngineFormState();
}

class _ApiEngineFormState extends ConsumerState<ApiEngineForm> {
  final _key = TextEditingController();
  late String _kind = _defaultKind(widget.engines);
  late Set<String> _selected = _shareable(_engine);
  bool _obscure = true;

  /// Compact only: reveal the model picker. First-run users just sign in and
  /// share every model (the default), so which-models-to-share is tucked behind
  /// an "Advanced" link until asked for.
  bool _showAdvanced = false;

  /// Which provider the block opens on: prefer a subscription (sign-in) provider
  /// like the ChatGPT/Codex seat, so it's ready to Start without pasting a key.
  /// Falls back to the first available provider when none use sign-in.
  static String _defaultKind(List<ApiEngine> engines) {
    final subscription = engines.where((e) => e.provider.usesSignIn);
    final chosen = subscription.isNotEmpty ? subscription.first : engines.first;
    return chosen.provider.kind;
  }

  /// True once the user chose to replace a key the CLI already had stored — only
  /// then do we show the key field for a provider with a saved key.
  bool _replaceKey = false;

  ApiEngine get _engine => widget.engines.firstWhere(
    (e) => e.provider.kind == _kind,
    orElse: () => widget.engines.first,
  );

  /// Everything this provider offers that isn't already on the grid from this
  /// machine — what "share all" means once some models are live. Ticking every
  /// box by default would otherwise re-offer a model that's already shared.
  Set<String> _shareable(ApiEngine engine) => {
    for (final model in engine.models)
      if (!widget.alreadyShared.contains(model.advertised)) model.advertised,
  };

  /// A stored key covers this start only while the user hasn't asked to replace it.
  bool get _usingStoredKey => _engine.hasStoredKey && !_replaceKey;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _onProviderChanged(String kind) {
    setState(() {
      _kind = kind;
      _selected = _shareable(_engine);
      _replaceKey = false;
      _key.clear();
    });
  }

  void _toggleModel(String advertised, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(advertised);
      } else {
        _selected.remove(advertised);
      }
    });
  }

  Future<void> _openKeyHelp(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Why Start can't run yet, or null when it can. Surfaced as a tooltip on the
  /// disabled button so it explains itself instead of sitting greyed out. A
  /// sign-in provider needs no key — signing in happens on Start.
  String? _startBlockedReason() {
    if (!_engine.provider.usesSignIn &&
        !_usingStoredKey &&
        _key.text.trim().isEmpty) {
      return 'Enter a valid API key to start sharing cloud models.';
    }
    if (_shareable(_engine).isEmpty) {
      return "You're already sharing every model ${_engine.provider.label} "
          'offers. Stop one above to change what you share.';
    }
    if (_selected.isEmpty) return 'Pick at least one model to share.';
    return null;
  }

  /// The Start button's label — honest about what pressing it does for this
  /// provider: paste-key providers start the engine; a sign-in provider signs in
  /// (or reuses a stored seat) then shares.
  String get _startLabel {
    if (!_engine.provider.usesSignIn) return 'Start cloud engine';
    return _usingStoredKey ? 'Share your subscription' : 'Sign in & share';
  }

  /// What the busy row says while the join is starting: a sign-in join sends the
  /// user to the browser, so point them there; other joins are just starting up.
  String get _busyLabel => _engine.provider.usesSignIn && !_usingStoredKey
      ? 'Signing in… finish it in your browser'
      : 'Starting…';

  void _start() {
    final engine = _engine;
    // Preserve whitelist order; serve-all sends no -m (the CLI's zero-config
    // default of "the whole whitelist this key can see").
    final chosen = [
      for (final model in engine.models)
        if (_selected.contains(model.advertised)) model.advertised,
    ];
    final serveAll = chosen.length == engine.models.length;
    ref
        .read(providerRunControllerProvider.notifier)
        .startApiEngine(
          network: widget.network.networkId,
          kind: engine.provider.kind,
          envVar: engine.provider.envVar,
          apiKey: _usingStoredKey ? '' : _key.text.trim(),
          models: serveAll ? const [] : chosen,
        );
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    // While this grid's join is still starting (a sign-in join is awaiting the
    // browser approval), swap Start for a busy row — feedback that it's working,
    // and a guard against a second join from a double-tap.
    final run = ref.watch(providerRunControllerProvider);
    final starting =
        run is ProviderRunActive &&
        run.grid == widget.network.networkId &&
        run.starting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.engines.length > 1) ...[
          _ProviderDropdown(
            engines: widget.engines,
            selectedKind: _kind,
            onChanged: _onProviderChanged,
          ),
          const SizedBox(height: 12),
        ],
        if (engine.provider.usesSignIn)
          _SignInPanel(label: engine.provider.label, signedIn: _usingStoredKey)
        else
          _KeyField(
            provider: engine.provider,
            controller: _key,
            obscure: _obscure,
            usingStoredKey: _usingStoredKey,
            onToggleObscure: () => setState(() => _obscure = !_obscure),
            onReplaceKey: () => setState(() => _replaceKey = true),
            onOpenHelp: _openKeyHelp,
          ),
        const SizedBox(height: 16),
        if (!widget.compact || _showAdvanced)
          _ModelMultiSelect(
            models: engine.models,
            selected: _selected,
            alreadyShared: widget.alreadyShared,
            onToggle: _toggleModel,
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = true),
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Advanced: choose which models to share'),
            ),
          ),
        if (!widget.compact && engine.lastVerified.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Model list updated ${_prettyDate(engine.lastVerified)}. '
            'Update Grid to refresh.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          // The "Billed to your own account" chip above already says who pays,
          // so this keeps only what the chip doesn't carry: for a subscription,
          // that the seat's allowance is what's spent; for a key, where the key
          // lives and where prompts go.
          engine.provider.usesSignIn
              ? 'Requests use your subscription’s own allowance.'
              : 'Your key stays on this computer; prompts go to '
                    '${engine.provider.label} for inference.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: starting
              ? _StartingRow(label: _busyLabel)
              : ListenableBuilder(
                  listenable: _key,
                  builder: (context, _) => EngineStartButton(
                    label: _startLabel,
                    blockedReason: _startBlockedReason(),
                    onPressed: _start,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Shown in place of Start while the join is starting: a spinner and a line that
/// tells the user what to do next (finish the browser sign-in, or just wait).
/// Also stops a double-tap from launching a second join.
class _StartingRow extends StatelessWidget {
  const _StartingRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const AppSpinner(),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// The credential row for a sign-in provider (a ChatGPT/Codex subscription):
/// there is no key to paste, so it explains what Start will do — open the
/// browser to sign in, or reuse a seat this machine already signed in with —
/// instead of showing a key field.
class _SignInPanel extends StatelessWidget {
  const _SignInPanel({required this.label, required this.signedIn});

  final String label;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = signedIn ? Icons.check_circle_outline : Icons.open_in_browser;
    final text = signedIn
        ? 'Signed in to your $label — Start shares it with the grid.'
        : 'No key needed — Start signs you in via your browser, then shares '
              'the seat.';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 18,
          color: signedIn
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

/// Provider chooser, shown only when more than one hosted provider is available.
class _ProviderDropdown extends StatelessWidget {
  const _ProviderDropdown({
    required this.engines,
    required this.selectedKind,
    required this.onChanged,
  });

  final List<ApiEngine> engines;
  final String selectedKind;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // AppSelectField, not DropdownButtonFormField: Material draws its own popup
    // edge-to-edge with square corners, which read as a different design system
    // beside the models menu right below it.
    return AppSelectField<String>(
      label: 'Provider',
      value: selectedKind,
      onChanged: onChanged,
      options: [
        for (final engine in engines)
          AppSelectOption(
            value: engine.provider.kind,
            label: engine.provider.label,
            // Say how each provider authenticates while the list is open — it's
            // the difference between pasting a key and a browser sign-in.
            detail: engine.provider.usesSignIn
                ? 'Sign in with your subscription'
                : 'Uses your API key',
          ),
      ],
    );
  }
}

/// The API-key input — or a "saved key" row when the CLI already has one, with a
/// path back to the field. Includes a show/hide toggle and a link to the
/// provider's key page.
class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.provider,
    required this.controller,
    required this.obscure,
    required this.usingStoredKey,
    required this.onToggleObscure,
    required this.onReplaceKey,
    required this.onOpenHelp,
  });

  final ApiProvider provider;
  final TextEditingController controller;
  final bool obscure;
  final bool usingStoredKey;
  final VoidCallback onToggleObscure;
  final VoidCallback onReplaceKey;
  final Future<void> Function(String url) onOpenHelp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (usingStoredKey) {
      return Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('Using your saved ${provider.label} key')),
          TextButton(
            onPressed: onReplaceKey,
            child: const Text('Use a different key'),
          ),
        ],
      );
    }

    final helpUrl = provider.keyHelpUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Provider API key'),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: kFieldTextStyle,
          decoration:
              labeledFieldDecoration(
                provider.keyHint,
                fill: AppCard.inset,
              ).copyWith(
                // Cap the toggle so it doesn't inflate the field above the theme's
                // field height (a bare IconButton is 48, the field is 44).
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 44,
                  maxWidth: 44,
                  maxHeight: 44,
                ),
                suffixIcon: IconButton(
                  tooltip: obscure ? 'Show key' : 'Hide key',
                  iconSize: 20,
                  icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: onToggleObscure,
                ),
              ),
        ),
        if (helpUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onOpenHelp(helpUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Find your API key'),
            ),
          ),
      ],
    );
  }
}

/// A compact multi-select for the whitelisted models: a field showing a summary
/// ("All available models (4)" / "2 of 4 models") that drops a checkbox menu.
/// All are shared by default; the menu stays open while ticking so several can
/// be picked in one go. Keeps the block short instead of a full checkbox list.
class _ModelMultiSelect extends StatelessWidget {
  const _ModelMultiSelect({
    required this.models,
    required this.selected,
    required this.alreadyShared,
    required this.onToggle,
  });

  final List<ApiEngineModel> models;
  final Set<String> selected;

  /// Models this machine already serves — shown, but not tickable: sharing one
  /// twice would advertise the same name to the grid twice.
  final Set<String> alreadyShared;
  final void Function(String advertised, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    // The menu opens full-width (not shrink-wrapped to the model names), so each
    // row carries the field width via a SizedBox — MenuStyle.minimumSize doesn't
    // widen the panel reliably. LayoutBuilder gives us that width.
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        // Line the menu up under the field's left edge, just below it.
        alignmentOffset: const Offset(0, 6),
        // Without this the panel takes the themed fill, which is within 1.02:1
        // of the block behind it (identical in light) — the menu had no edge.
        style: appMenuStyle(),
        builder: (context, controller, _) => _ModelField(
          summary: _summary(),
          onTap: controller.isOpen ? controller.close : controller.open,
        ),
        menuChildren: [
          for (final model in models)
            _ModelMenuRow(
              model: model,
              width: constraints.maxWidth,
              checked: selected.contains(model.advertised),
              shared: alreadyShared.contains(model.advertised),
              onToggle: () => onToggle(
                model.advertised,
                !selected.contains(model.advertised),
              ),
            ),
        ],
      ),
    );
  }

  /// What the field says when closed. Counts against what's actually on offer —
  /// with some models already live, "all" means all the ones left to share, and
  /// nothing to share at all says so rather than reading "No models selected".
  String _summary() {
    final offered = models.length - alreadyShared.length;
    if (offered <= 0) return 'Already sharing every model';
    if (selected.isEmpty) return 'No models selected';
    if (selected.length == offered) {
      return offered == models.length
          ? 'All available models ($offered)'
          : 'All $offered models left to share';
    }
    return '${selected.length} of $offered models';
  }
}

/// The tappable field that opens the model menu: a borderless capsule matching
/// the app's other fields, showing the current [summary] with a dropdown
/// affordance.
class _ModelField extends StatelessWidget {
  const _ModelField({required this.summary, required this.onTap});

  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Models available to the grid'),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            isEmpty: false,
            decoration: labeledFieldDecoration('', fill: AppCard.inset),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    summary,
                    overflow: TextOverflow.ellipsis,
                    style: kFieldTextStyle,
                  ),
                ),
                // Size 24 (a dropdown's default arrow) so the field matches the
                // theme's field height instead of shrinking to the 18px icon
                // theme.
                const Icon(Icons.arrow_drop_down, size: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One checkbox row in the model menu — the model name over its context/notes,
/// stretched to the field [width]. Toggling never closes the menu, so several
/// can be picked in a pass.
class _ModelMenuRow extends StatelessWidget {
  const _ModelMenuRow({
    required this.model,
    required this.width,
    required this.checked,
    required this.shared,
    required this.onToggle,
  });

  final ApiEngineModel model;
  final double width;
  final bool checked;

  /// Already live on the grid from this machine — the row shows it, greyed and
  /// untickable, so the model is accounted for rather than silently missing.
  final bool shared;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppControl.radius);
    // Same construction as AppSelectField's rows and the chat model picker's:
    // MenuItemButton is unthemed here, so its M3 defaults (square corners, 14pt
    // text, Material's grey hover, an ink ripple) would put this menu outside
    // the design system. See _OptionRow in app_select_field.dart.
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: shared ? null : onToggle,
            borderRadius: radius,
            hoverColor: AppSurface.hoverFill,
            splashFactory: NoSplash.splashFactory,
            child: Ink(
              decoration: BoxDecoration(
                color: checked ? AppSurface.accentWash : Colors.transparent,
                borderRadius: radius,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    shared
                        ? Icons.check_circle_outline
                        : (checked
                              ? Icons.check_box
                              : Icons.check_box_outline_blank),
                    size: AppControl.iconSize,
                    // onSurfaceVariant, not textFaint: on the lifted menu panel
                    // the faint ink lands at 2.80:1, under the 3.0 WCAG 1.4.11
                    // asks of a UI glyph.
                    color: checked
                        ? AppPalette.accentMuted
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Weight carries the selection as well as the tick, so
                        // which rows are in play reads from the text alone.
                        Text(
                          model.vendorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppControl.fontSize,
                            height: 1.2,
                            fontWeight: checked
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: shared
                                ? AppPalette.textSecondary
                                : AppPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          shared ? 'Already sharing' : _meta(model),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.28,
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
      ),
    );
  }

  static String _meta(ApiEngineModel model) {
    final ctx = '${_ctxLabel(model.contextWindow)} context';
    return model.notes.isEmpty ? ctx : '$ctx · ${model.notes}';
  }
}

const _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `2026-07-08` → `8 Jul 2026`; returns the input unchanged if it isn't an ISO
/// date, so a reformatted CLI value never blanks the freshness note.
String _prettyDate(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) return iso;
  return '$day ${_monthAbbr[month - 1]} ${parts[0]}';
}

/// A compact context-window label, e.g. `1.1M` / `400K` — a hint, not exact.
String _ctxLabel(int tokens) {
  if (tokens >= 1000000) {
    final millions = tokens / 1000000;
    final text = millions == millions.roundToDouble()
        ? millions.toStringAsFixed(0)
        : millions.toStringAsFixed(1);
    return '${text}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}
