import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/context_window_field.dart';
import '../../../shared/widgets/form_plate.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/node_name_field.dart';
import '../../../core/context_length.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/engine_endpoint.dart';
import '../logic/engine_reachability.dart';
import '../logic/provider_run_controller.dart';
import 'engine_block.dart';
import 'server_address_field.dart';

/// A card for connecting an external inference server (Ollama, vLLM, etc.) with
/// Base URL / Model / Advertise-as / grid-name fields and a Start button. Wraps
/// either a plain [EngineBlock] or a [CollapsibleEngineBlock] depending on
/// [collapsible].
class ExternalServerBlock extends ConsumerStatefulWidget {
  const ExternalServerBlock({
    super.key,
    required this.network,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.initialEndpoint = '',
    this.initialModel = '',
    this.initialAdvertise = '',
    this.suggestedModels = const [],
    this.collapsible = false,
  });

  final NetworkCredential network;
  final IconData icon;
  final String title;
  final String subtitle;
  final String initialEndpoint;
  final String initialModel;
  final String initialAdvertise;

  /// Models the framework reported; non-empty turns the Model field into a
  /// dropdown (pick one of many) instead of a free-text box.
  final List<String> suggestedModels;

  /// Show the form collapsed behind a tappable header (the advanced manual
  /// card), instead of always-open like the detected-framework cards.
  final bool collapsible;

  @override
  ConsumerState<ExternalServerBlock> createState() =>
      _ExternalServerBlockState();
}

class _ExternalServerBlockState extends ConsumerState<ExternalServerBlock> {
  late final _endpoint = TextEditingController(text: widget.initialEndpoint);
  late final _model = TextEditingController(text: widget.initialModel);
  late final _advertise = TextEditingController(text: widget.initialAdvertise);

  /// The context window this engine will advertise, in tokens.
  ///
  /// Null only until the first build settles it — the setting is required, so
  /// there is no "unset" to send. It starts at [defaultContextLength] (200k, or
  /// the server's own ceiling when it serves less) and the person moves it.
  int? _contextTokens;

  /// What this computer joins under — pre-filled with its own name, so the field
  /// shows what a start would actually use rather than a blank box.
  late final _nodeName = TextEditingController(
    text: ref.read(nodeNameProvider),
  );

  /// Once the user types their own "Advertise as", stop auto-filling it — don't
  /// clobber a name they chose.
  bool _advertiseEdited = false;

  /// Guards the programmatic write below so it isn't mistaken for a user edit.
  bool _syncingAdvertise = false;

  @override
  void initState() {
    super.initState();
    _model.addListener(_syncAdvertiseToModel);
    _advertise.addListener(_markAdvertiseEdited);
    _endpoint.addListener(_scheduleCheck);
    // An address handed in by the caller (a detected framework) is already
    // usable — check it now rather than waiting for a keystroke that isn't
    // coming.
    _scheduleCheck();
  }

  /// Mirror the chosen model into "Advertise as" (via [deriveAdvertiseName]) so
  /// switching models keeps the advertised name in step — until the user
  /// overrides it by hand.
  void _syncAdvertiseToModel() {
    if (_advertiseEdited) return;
    final derived = deriveAdvertiseName(_model.text.trim());
    if (derived == _advertise.text) return;
    _syncingAdvertise = true;
    _advertise.text = derived;
    _syncingAdvertise = false;
  }

  void _markAdvertiseEdited() {
    if (!_syncingAdvertise) _advertiseEdited = true;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _model.removeListener(_syncAdvertiseToModel);
    _advertise.removeListener(_markAdvertiseEdited);
    _endpoint.removeListener(_scheduleCheck);
    _endpoint.dispose();
    _model.dispose();
    _advertise.dispose();
    _nodeName.dispose();
    super.dispose();
  }

  /// How long to let someone keep typing before asking their server anything.
  ///
  /// An address is typed a character at a time and most of those characters are
  /// not an address yet, so a check per keystroke would be a burst of requests
  /// at whatever machine they eventually name.
  static const _typingPause = Duration(milliseconds: 600);

  Timer? _debounce;

  /// True from the moment a check is scheduled until its answer lands — the
  /// debounce included, so the button never flickers to "ready" in the gap
  /// between the last keystroke and the request.
  bool _checking = false;

  /// The last answer, and the base it was about. The pair is what makes a
  /// result trustworthy: an answer for an address the user has since edited
  /// says nothing about the one now in the field.
  EngineReach? _reach;
  String? _checkedBase;

  /// Rises with every check started, so an answer that arrives after a newer
  /// check began is dropped instead of overwriting it.
  int _checkToken = 0;

  /// Ask the server what it serves, as soon as the address looks like one.
  ///
  /// **Not** on Start, which is where this began and where it deadlocked: the
  /// button is blocked until a model is chosen, and the model list only exists
  /// once the server has been asked. Nothing could ever run.
  void _scheduleCheck() {
    final address = readEngineAddress(_endpoint.text);
    _debounce?.cancel();
    if (address is! EngineAddressReady) {
      // Half-typed or refused: drop whatever a previous address answered, and
      // make sure an in-flight reply can't land on top of it.
      _checkToken++;
      setState(() {
        _checking = false;
        _reach = null;
        _checkedBase = null;
      });
      return;
    }
    if (address.base == _checkedBase) return;
    setState(() => _checking = true);
    _debounce = Timer(_typingPause, () => unawaited(_check(address)));
  }

  /// One look at [address], recorded only if it is still the address on screen.
  Future<void> _check(EngineAddressReady address) async {
    final token = ++_checkToken;
    final reach = await probeEngine(address);
    if (!mounted || token != _checkToken) return;
    setState(() {
      _checking = false;
      _reach = reach;
      _checkedBase = address.base;
    });
    _adoptAnswers(reach);
  }

  /// Fill in what the server just told us, without touching what the user has
  /// already typed — a prefill that overwrites is worse than no prefill.
  void _adoptAnswers(EngineReach reach) {
    if (reach is! EngineReachable) return;
    // One model is not a choice, it is the answer.
    if (reach.models.length == 1 &&
        reach.canOfferModels &&
        _model.text.trim().isEmpty) {
      _model.text = reach.models.single;
    }
    // A server that states its window has settled the question: the slider's
    // ceiling becomes what it serves, and the value lands inside it. Only for
    // an untouched setting — a number someone chose is not ours to move.
    if (reach.contextLength case final served? when _contextTokens == null) {
      setState(() => _contextTokens = defaultContextLength(served));
    }
  }

  /// The most context this engine can be set to.
  ///
  /// The server's own figure when it gave one, so the slider cannot be dragged
  /// past what it actually serves. Otherwise a plain ceiling: nothing here knows
  /// the real limit, and a slider still has to end somewhere.
  int get _contextMax => switch (_reachForCurrent) {
    EngineReachable(:final contextLength?) => contextLength,
    _ => _unknownContextCeiling,
  };

  /// Where the slider stops when the server hasn't said what it serves.
  ///
  /// 1M rather than the built-in engine's 256k: this card points at somebody
  /// else's server, which may well be a hosted gateway in front of a model whose
  /// window is far past anything that fits on this machine. Capping the slider
  /// below what their engine serves would make the app the reason they cannot
  /// advertise it.
  ///
  /// TODO(BE): a window set above what the engine really serves is advertised
  /// to the relay as-is, and the router picks nodes on it — so an over-set node
  /// wins work it then fails. Nothing can catch that from here: the server did
  /// not say. It is caught the moment an engine reports `max_model_len`, which
  /// is why that path narrows the ceiling rather than only prefilling a value.
  static const _unknownContextCeiling = 1024 * 1024;

  /// The value to show: what was chosen, or the default for the current
  /// ceiling until someone chooses.
  int get _contextValue => _contextTokens ?? defaultContextLength(_contextMax);

  /// Join, using the address that was checked rather than the raw text.
  ///
  /// Checking one URL and joining with another is the failure this whole path
  /// exists to prevent, so the two read from the same place. The Start button
  /// is already blocked unless the address is ready **and** its check came back
  /// reachable (see [ServerForm._blockedReason]) — the guard here is the
  /// type-level half of that statement.
  void _start() {
    final address = readEngineAddress(_endpoint.text);
    if (address is! EngineAddressReady) return;
    ref.read(analyticsProvider).engineSetupSubmitted('own_server');
    ref
        .read(providerRunControllerProvider.notifier)
        .startExternal(
          network: widget.network.networkId,
          endpoint: address.base,
          model: _model.text.trim(),
          contextLength: _contextValue,
          advertiseAs: _advertise.text.trim(),
          // Blank falls back to this computer's own name, inside the controller
          // — so an emptied field behaves the same as one never touched.
          nodeName: _nodeName.text,
        );
  }

  /// The last answer, but only if it was about the address currently on screen.
  EngineReach? get _reachForCurrent {
    final address = readEngineAddress(_endpoint.text);
    if (address is! EngineAddressReady) return null;
    return address.base == _checkedBase ? _reach : null;
  }

  /// Names to offer in the Model field: what this server just said it serves,
  /// falling back to whatever the caller detected.
  ///
  /// Offered only for an engine the app recognised — see
  /// [EngineReachable.canOfferModels]. Anything else keeps the text field, which
  /// is what typing a name by hand has always been.
  List<String> get _models => switch (_reachForCurrent) {
    EngineReachable(:final models, :final canOfferModels) when canOfferModels =>
      models,
    _ => widget.suggestedModels,
  };

  /// Ask again after a failure, without making the user retype a good address —
  /// a server that was still starting up is the common case here.
  void _retry() {
    setState(() {
      _reach = null;
      _checkedBase = null;
    });
    _scheduleCheck();
  }

  @override
  Widget build(BuildContext context) {
    final form = ServerForm(
      endpoint: _endpoint,
      model: _model,
      contextMax: _contextMax,
      contextValue: _contextValue,
      onContextChanged: (tokens) => setState(() => _contextTokens = tokens),
      contextNote: switch (_reachForCurrent) {
        EngineReachable(:final contextLength?) =>
          'Your server reports ${formatContextLength(contextLength)}.',
        _ => null,
      },
      advertise: _advertise,
      nodeName: _nodeName,
      suggestedModels: _models,
      checking: _checking,
      reach: _reachForCurrent,
      onRetry: _retry,
      onStart: _start,
    );
    if (widget.collapsible) {
      return CollapsibleEngineBlock(
        icon: widget.icon,
        title: widget.title,
        subtitle: widget.subtitle,
        child: form,
      );
    }
    return EngineBlock(
      icon: widget.icon,
      title: widget.title,
      subtitle: widget.subtitle,
      child: form,
    );
  }
}

/// The external engine form body: the server address, Model, Advertise-as and
/// this computer's grid name over a Start button. The controllers stay the
/// source of truth so [onStart] reads them; [suggestedModels] picks the Model
/// field shape.
class ServerForm extends StatelessWidget {
  const ServerForm({
    super.key,
    required this.endpoint,
    required this.model,
    required this.contextMax,
    required this.contextValue,
    required this.onContextChanged,
    required this.contextNote,
    required this.advertise,
    required this.nodeName,
    required this.suggestedModels,
    required this.checking,
    required this.reach,
    required this.onRetry,
    required this.onStart,
  });

  final TextEditingController endpoint;
  final TextEditingController model;
  final int contextMax;
  final int contextValue;
  final ValueChanged<int> onContextChanged;

  /// A line under the description when the server named its own window.
  final String? contextNote;

  final TextEditingController advertise;
  final TextEditingController nodeName;
  final List<String> suggestedModels;
  final bool checking;
  final EngineReach? reach;
  final VoidCallback onRetry;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Five fields in one column read as five steps. Ruled into three
        // groups they read as what they are: where the engine is, what it is
        // called, and how much it remembers.
        FormPlate(
          sections: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ServerAddressField(
                  controller: endpoint,
                  checking: checking,
                  reach: reach,
                  onRetry: onRetry,
                ),
                const SizedBox(height: 14),
                ModelField(model: model, suggestedModels: suggestedModels),
              ],
            ),
            FieldPair(
              first: AdvertiseAsField(
                controller: advertise,
                hintText: 'qwen3-31b.gguf',
                optional: true,
              ),
              second: NodeNameField(controller: nodeName),
            ),
            ContextWindowField(
              max: contextMax,
              value: contextValue,
              note: contextNote,
              // Already inside a plate that rules it off from the fields above,
              // so the recessed tile would be a box inside a box.
              inline: true,
              onChanged: onContextChanged,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: Listenable.merge([endpoint, model]),
            builder: (context, _) => EngineStartButton(
              label: checking ? 'Checking…' : 'Start engine',
              blockedReason: _blockedReason(),
              onPressed: onStart,
            ),
          ),
        ),
      ],
    );
  }

  /// Why Start can't be pressed yet, or null when it can.
  ///
  /// The address is judged by the same reader the field itself uses, so the
  /// button and the line under the field can never disagree about whether an
  /// address is usable.
  ///
  /// Start needs a server that **answered**, not merely an address that parses.
  /// That is the fail-closed half of this screen: the CLI will happily join an
  /// address nothing is listening on, and the node it registers then fails every
  /// message while looking perfectly healthy.
  String? _blockedReason() {
    if (checking) return 'Checking the server…';
    return switch (readEngineAddress(endpoint.text)) {
      EngineAddressEmpty() => 'Fill in the server address to start.',
      EngineAddressRejected(:final message) => message,
      EngineAddressReady() => _serverBlockedReason(),
    };
  }

  /// The half of [_blockedReason] that applies once the address itself is fine.
  String? _serverBlockedReason() => switch (reach) {
    // The detail is already spelled out under the field; repeating it on the
    // button would say the same sentence twice on one screen.
    EngineUnreachable() => "Grid couldn't reach that server.",
    EngineReachable() when model.text.trim().isEmpty =>
      'Choose the model this server runs.',
    EngineReachable() => null,
    // No answer yet and not checking — only reachable for an instant, between
    // the address becoming valid and the check being scheduled.
    null => 'Checking the server…',
  };
}

/// Model is a dropdown when the framework reports models (pick one of many), and
/// a free-text field otherwise (manual base URL → type the name). The [model]
/// controller stays the source of truth either way.
class ModelField extends StatelessWidget {
  const ModelField({
    super.key,
    required this.model,
    required this.suggestedModels,
  });

  final TextEditingController model;
  final List<String> suggestedModels;

  @override
  Widget build(BuildContext context) {
    if (suggestedModels.isEmpty) {
      return LabeledField(
        label: 'Model',
        controller: model,
        hint: 'gemma4-31b.gguf',
      );
    }
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final value = suggestedModels.contains(model.text) ? model.text : null;
        // AppSelectField for the same reason as the other two pickers: a
        // Material dropdown's popup can't match the app's floating menus.
        return AppSelectField<String>(
          label: 'Model',
          value: value,
          options: [
            for (final m in suggestedModels)
              AppSelectOption(value: m, label: m),
          ],
          onChanged: (v) => model.text = v,
        );
      },
    );
  }
}
