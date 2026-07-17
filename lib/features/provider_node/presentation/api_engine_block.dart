import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/provider_run_controller.dart';
import 'engine_block.dart';

/// The "Cloud Provider" engine block: serve a hosted model (e.g. OpenAI's) to
/// the grid using the user's own API key, with no local engine, model download,
/// or setup.
///
/// Hidden entirely when no hosted provider is available — either `grid` is
/// missing or the installed CLI whitelists none we can present ([apiEnginesProvider]).
/// The block never appears for a provider a `grid join --api` would reject.
class ApiEngineBlock extends ConsumerWidget {
  const ApiEngineBlock({super.key, required this.network});

  final NetworkCredential network;

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
    return EngineBlock(
      icon: Icons.cloud_outlined,
      title: 'Cloud Provider',
      subtitle: hasSignIn
          ? 'Share a hosted provider’s models — with your own API key or your '
                'ChatGPT subscription. No local model download required.'
          : 'Share models from a hosted provider using your own API key. '
                'No local model download required.',
      child: _ApiEngineForm(network: network, engines: available),
    );
  }
}

/// Pick a provider (when more than one is available), paste an API key, choose
/// which models to share, and start. The key travels to the CLI via the
/// environment (never argv), and a key the CLI already saved lets the user start
/// again without re-pasting.
class _ApiEngineForm extends ConsumerStatefulWidget {
  const _ApiEngineForm({required this.network, required this.engines});

  final NetworkCredential network;
  final List<ApiEngine> engines;

  @override
  ConsumerState<_ApiEngineForm> createState() => _ApiEngineFormState();
}

class _ApiEngineFormState extends ConsumerState<_ApiEngineForm> {
  final _key = TextEditingController();
  late String _kind = widget.engines.first.provider.kind;
  late Set<String> _selected = _allModels(_engine);
  bool _obscure = true;

  /// True once the user chose to replace a key the CLI already had stored — only
  /// then do we show the key field for a provider with a saved key.
  bool _replaceKey = false;

  ApiEngine get _engine => widget.engines.firstWhere(
    (e) => e.provider.kind == _kind,
    orElse: () => widget.engines.first,
  );

  static Set<String> _allModels(ApiEngine engine) => {
    for (final model in engine.models) model.advertised,
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
      _selected = _allModels(_engine);
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
        _ModelMultiSelect(
          models: engine.models,
          selected: _selected,
          onToggle: _toggleModel,
        ),
        if (engine.lastVerified.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '${engine.provider.label}’s current models · list updated '
            '${_prettyDate(engine.lastVerified)}. Update Grid to refresh it.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          engine.provider.usesSignIn
              ? 'You stay signed in on this computer. Grid never bills you — '
                    'requests to these models spend your subscription’s own '
                    'monthly allowance.'
              : 'Your key stays on this computer. When grid requests use these '
                    'models, prompts are sent to ${engine.provider.label} for '
                    'inference.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: _key,
            builder: (context, _) => _StartButton(
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

/// Start, carrying the reason it can't run yet as a tooltip on the disabled
/// button — a greyed-out button that never says why is a dead end for a
/// first-time user.
class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.label,
    required this.blockedReason,
    required this.onPressed,
  });

  final String label;

  /// Why the button is disabled, or null when it can start.
  final String? blockedReason;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final reason = blockedReason;
    final button = FilledButton.icon(
      onPressed: reason == null ? onPressed : null,
      icon: const Icon(Icons.play_arrow),
      label: Text(label),
    );
    if (reason == null) return button;
    return Tooltip(message: reason, child: button);
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
        ? 'Signed in to your $label. Starting shares it with the grid — no '
              'browser needed.'
        : 'No API key needed. Starting opens your browser to sign in to your '
              '$label; approve it once and Grid serves the seat.';
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
    return DropdownButtonFormField<String>(
      initialValue: selectedKind,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Provider',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final engine in engines)
          DropdownMenuItem(
            value: engine.provider.kind,
            child: Text(engine.provider.label),
          ),
      ],
      onChanged: (kind) {
        if (kind != null) onChanged(kind);
      },
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
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Provider API key',
            hintText: provider.keyHint,
            border: const OutlineInputBorder(),
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
    required this.onToggle,
  });

  final List<ApiEngineModel> models;
  final Set<String> selected;
  final void Function(String advertised, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    // The menu opens full-width (not shrink-wrapped to the model names), so each
    // row carries the field width via a SizedBox — MenuStyle.minimumSize doesn't
    // widen the panel reliably. LayoutBuilder gives us that width.
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        // Line the menu up under the field's left edge, just below it.
        alignmentOffset: const Offset(0, 4),
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
              onToggle: () => onToggle(
                model.advertised,
                !selected.contains(model.advertised),
              ),
            ),
        ],
      ),
    );
  }

  String _summary() {
    if (selected.isEmpty) return 'No models selected';
    if (selected.length == models.length) {
      return 'All available models (${models.length})';
    }
    return '${selected.length} of ${models.length} models';
  }
}

/// The tappable field that opens the model menu: a fixed-height outlined box
/// showing the current [summary] with a dropdown affordance.
class _ModelField extends StatelessWidget {
  const _ModelField({required this.summary, required this.onTap});

  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: false,
        decoration: const InputDecoration(
          labelText: 'Models available to the grid',
          border: OutlineInputBorder(),
        ),
        child: Row(
          children: [
            Expanded(child: Text(summary, overflow: TextOverflow.ellipsis)),
            // Size 24 (a dropdown's default arrow) so the field matches the
            // theme's field height instead of shrinking to the 18px icon theme.
            const Icon(Icons.arrow_drop_down, size: 24),
          ],
        ),
      ),
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
    required this.onToggle,
  });

  final ApiEngineModel model;
  final double width;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: MenuItemButton(
        closeOnActivate: false,
        leadingIcon: Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 20,
          color: checked
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        onPressed: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(model.vendorName),
              Text(
                _meta(model),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
