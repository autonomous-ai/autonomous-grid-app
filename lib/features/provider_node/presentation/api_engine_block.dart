import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/theme/share_page_theme.dart';
import '../../../shared/widgets/form_plate.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/api_engine_choices.dart';
import '../logic/engine_slots.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'engine_block.dart';
import 'engine_cost_chip.dart';
import 'task_serving_panel.dart';

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
  /// Set by the Share Intelligence page, where the add-engine picker above
  /// already names this path. Onboarding leaves it off: there the block stands
  /// alone.
  final bool headerless;

  /// Trims the secondary copy (the model-freshness line) for a first-run
  /// context like onboarding, where the full form reads as a wall of text next
  /// to the other one-line options. The Share Intelligence screen keeps the
  /// full detail (`compact: false`).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = ref.watch(apiEnginesProvider);
    // An optional path: while probing, or if no provider resolves / the catalog
    // read fails, we simply don't show the block rather than a broken shell.
    final available = engines.asData?.value ?? const <ApiEngine>[];
    if (available.isEmpty) return const SizedBox.shrink();

    // Only claim "or a coding CLI you already use" when one is actually on this
    // computer — otherwise the subtitle promises a road that ends in "install
    // it first".
    final hasSeat = seatEngines(available).isNotEmpty;
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
      subtitle: hasSeat
          ? 'Your own API key, or a coding CLI already on this computer. '
                'Nothing to download.'
          : 'A hosted provider, using a key you already pay for. Nothing '
                'to download.',
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
/// per way in (a CLI already on this computer, a pasted key) — instead of the
/// single "Cloud Provider" block with a provider dropdown that this screen uses.
/// Hand it the [engines] that card is about; with one, it drops the dropdown.
class ApiEngineForm extends ConsumerStatefulWidget {
  const ApiEngineForm({
    super.key,
    required this.network,
    required this.engines,
    required this.compact,
    this.alreadyShared = const {},
  });

  final NetworkCredential network;
  final List<ApiEngine> engines;

  /// Advertised names this machine already serves from a hosted provider — off
  /// the table, so the same model can't be shared twice. Empty where the form is
  /// only reachable with nothing serving at all (the add-engine cards).
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

  /// Which provider the block opens on: prefer a CLI seat that's actually on
  /// this computer, so it's ready to Start with nothing to paste and nothing to
  /// install. Falls back to the first available provider otherwise — including
  /// when the only seats are ones this machine hasn't got, which would open the
  /// block on a dead end.
  static String _defaultKind(List<ApiEngine> engines) {
    final ready = seatEngines(engines);
    return (ready.isNotEmpty ? ready.first : engines.first).provider.kind;
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

  /// Hand a help link to the browser — where to find a key, or where to get the
  /// CLI a seat needs.
  Future<void> _openUrl(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Why Start can't run yet, or null when it can. Surfaced as a tooltip on the
  /// disabled button so it explains itself instead of sitting greyed out. A CLI
  /// seat needs no key — but it does need its CLI to be here.
  String? _startBlockedReason() {
    final provider = _engine.provider;
    if (provider.isSeat && _engine.seatFound != true) {
      return '${provider.label} is not on this computer yet, so there is '
          'nothing for the grid to run.';
    }
    if (!provider.isSeat && !_usingStoredKey && _key.text.trim().isEmpty) {
      return 'Enter a valid API key to start sharing cloud models.';
    }
    if (_shareable(_engine).isEmpty) {
      return "You're already sharing every model ${provider.label} "
          'offers. Stop one above to change what you share.';
    }
    if (_selected.isEmpty) return 'Pick at least one model to share.';
    return null;
  }

  /// The Start button's label — honest about what pressing it does for this
  /// provider: a key provider starts a cloud engine, a seat shares the CLI
  /// that's already here.
  String get _startLabel => _engine.provider.isSeat
      ? 'Share ${_engine.provider.label}'
      : 'Start cloud engine';

  void _start() {
    ref.read(analyticsProvider).engineSetupSubmitted('api_key');
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
          provider: engine.provider,
          apiKey: _usingStoredKey ? '' : _key.text.trim(),
          models: serveAll ? const [] : chosen,
        );
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    // While this grid's join is still starting, swap Start for a busy row —
    // feedback that it's working, and a guard against a second join from a
    // double-tap.
    final run = ref.watch(providerRunControllerProvider);
    final starting =
        run is ProviderRunActive &&
        run.grid == widget.network.networkId &&
        run.starting;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Two questions, ruled apart: whose account answers, and which of its
        // models this grid is allowed to ask for. They used to run together
        // down one column, where the second read as more of the first.
        FormPlate(
          sections: [
            Column(
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
                if (engine.provider.isSeat) ...[
                  _SeatPanel(
                    provider: engine.provider,
                    found: engine.seatFound == true,
                    onOpenSetup: _openUrl,
                  ),
                  // Only under the Claude seat: a distributed task runs Claude
                  // Code, so this is the one join whose environment the task
                  // loop reads.
                  if (engine.provider.kind == kClaudeSeatKind) ...[
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    const TaskServingPanel(),
                  ],
                ] else
                  _KeyField(
                    provider: engine.provider,
                    controller: _key,
                    obscure: _obscure,
                    usingStoredKey: _usingStoredKey,
                    onToggleObscure: () => setState(() => _obscure = !_obscure),
                    onReplaceKey: () => setState(() => _replaceKey = true),
                    onOpenHelp: _openUrl,
                  ),
                // A seat spends an allowance rather than a key, and has no
                // field of its own to hang the note under — so it keeps it
                // here. The key path carries its own, inside [_KeyField].
                if (engine.provider.isSeat) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Requests run through ${engine.provider.label} here and '
                    'spend its own allowance.',
                    style: quiet,
                  ),
                ],
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FieldLabel("Models you're willing to share"),
                Text(
                  'Only the ones you pick get offered to the grid.',
                  style: quiet,
                ),
                const SizedBox(height: 10),
                if (!widget.compact || _showAdvanced)
                  _ModelPills(
                    models: engine.models,
                    selected: _selected,
                    alreadyShared: widget.alreadyShared,
                    onToggle: _toggleModel,
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _showAdvanced = true),
                      child: const Text('Choose which models to share →'),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (starting)
          const Align(
            alignment: Alignment.centerLeft,
            child: _StartingRow(label: 'Starting…'),
          )
        else
          ListenableBuilder(
            listenable: _key,
            builder: (context, _) {
              final blocked = _startBlockedReason();
              return Wrap(
                spacing: ShareMetrics.buttonGap,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  EngineStartButton(
                    label: _startLabel,
                    blockedReason: blocked,
                    onPressed: _start,
                  ),
                  // Beside the button rather than only inside its tooltip: a
                  // disabled control that will not say why is the shape people
                  // stare at.
                  if (blocked != null)
                    Text(blocked, style: ShareType.buttonHelper),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// Shown in place of Start while the join is starting: a spinner and a line
/// saying so. Also stops a double-tap from launching a second join.
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

/// The credential row for a CLI seat: there is no key to paste and no account to
/// hand over, so it says what the grid will actually run — and, when that CLI
/// isn't here, where to get it, rather than leaving a greyed-out Start.
///
/// It says "found", never "signed in". Whether the CLI is signed in is the
/// seat's own check at join time; claiming it here from a file on disk is
/// exactly the kind of label that reads "Connected" while nothing is (§5).
class _SeatPanel extends StatelessWidget {
  const _SeatPanel({
    required this.provider,
    required this.found,
    required this.onOpenSetup,
  });

  final ApiProvider provider;

  /// Whether [ApiProvider.binary] is on this computer.
  final bool found;
  final Future<void> Function(String url) onOpenSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final setupUrl = provider.setupUrl;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          found ? Icons.check_circle_outline : Icons.download_outlined,
          size: 18,
          color: found
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                found
                    ? '${provider.label} is on this computer. The grid runs it '
                          'with the sign-in it already has.'
                    : "${provider.label} isn't on this computer yet. Install it "
                          'and sign in, then come back here.',
              ),
              if (!found && setupUrl != null)
                TextButton.icon(
                  onPressed: () => onOpenSetup(setupUrl),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text('Get ${provider.label}'),
                ),
            ],
          ),
        ),
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
            // Say what each provider needs while the list is open — it's the
            // difference between pasting a key, sharing a CLI that's already
            // here, and one that would have to be installed first.
            detail: _providerDetail(engine),
          ),
      ],
    );
  }

  static String _providerDetail(ApiEngine engine) {
    if (!engine.provider.isSeat) return 'Uses your API key';
    return engine.seatFound == true
        ? 'Already on this computer'
        : 'Not installed here yet';
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
        // Named for the provider it belongs to, as the design has it: on a
        // build that whitelists one provider, "Provider API key" makes the
        // reader work out which provider from the dropdown that isn't there.
        FieldLabel('${provider.label} API key'),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          // Mono, as the design sets it: a key is a string you check character
          // by character, and `l`/`1` and `O`/`0` are the two pairs a
          // proportional face makes hardest to tell apart.
          style: kFieldTextStyle.copyWith(
            fontFamily: AppFont.monoDefault,
            letterSpacing: 0.2,
          ),
          decoration:
              labeledFieldDecoration(
                provider.keyHint,
                fill: AppCard.inset,
                skin: FieldSkinScope.maybeOf(context),
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
        const SizedBox(height: 4),
        // The way to the key, and nothing else. The design puts "Read-only
        // checks only. No billing changes." beside it, which this app cannot
        // say — the key answers questions, which is what bills the account.
        if (helpUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => onOpenHelp(helpUrl),
              child: const Text('Where to find your key →'),
            ),
          ),
      ],
    );
  }
}

/// The whitelisted models as pills you switch on and off.
///
/// The design's control, and the right one for this list: every model is a
/// yes/no, they are short, and there are a handful. A dropdown summarising them
/// as "All available models (4)" made the reader open a menu to find out what
/// the four *were* — which is the same mistake the three stacked routes used to
/// make, one control down.
///
/// A model this machine already serves is shown, spent, and untappable: sharing
/// one twice would advertise the same name to the grid twice, and leaving it out
/// would make it look as though the provider never offered it.
class _ModelPills extends StatelessWidget {
  const _ModelPills({
    required this.models,
    required this.selected,
    required this.alreadyShared,
    required this.onToggle,
  });

  final List<ApiEngineModel> models;
  final Set<String> selected;
  final Set<String> alreadyShared;
  final void Function(String advertised, bool selected) onToggle;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final model in models)
        _ModelPill(
          // "openai:gpt-5.4" is the name the grid advertises, and every pill
          // here carries the same prefix — a column of it says nothing the
          // label above has not, and it is what pushed four short names onto
          // two rows.
          label: model.advertised.split(':').last,
          state: alreadyShared.contains(model.advertised)
              ? _PillState.shared
              : selected.contains(model.advertised)
              ? _PillState.on
              : _PillState.off,
          onToggle: () =>
              onToggle(model.advertised, !selected.contains(model.advertised)),
        ),
    ],
  );
}

enum _PillState { on, off, shared }

/// One model, and whether the grid may ask for it.
class _ModelPill extends StatelessWidget {
  const _ModelPill({
    required this.label,
    required this.state,
    required this.onToggle,
  });

  final String label;
  final _PillState state;
  final VoidCallback onToggle;

  String get _suffix => switch (state) {
    _PillState.on => 'on',
    _PillState.off => 'off',
    _PillState.shared => 'sharing',
  };

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final live = state != _PillState.off;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: live
            ? SharePalette.accent.withValues(alpha: 0.09)
            : SharePalette.fieldFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: live
              ? SharePalette.accent.withValues(alpha: 0.28)
              : SharePalette.fieldRim,
        ),
      ),
      child: Text(
        '$label · $_suffix',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: AppFont.medium,
          color: live ? SharePalette.accentHover : SharePalette.body,
        ),
      ),
    );
    if (state == _PillState.shared) {
      return Tooltip(
        message: 'Already shared with the grid from this computer.',
        child: Opacity(opacity: 0.7, child: pill),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: pill,
      ),
    );
  }
}
