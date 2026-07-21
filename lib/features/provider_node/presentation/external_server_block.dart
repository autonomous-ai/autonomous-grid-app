import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/advertise_as_field.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/provider_run_controller.dart';
import 'engine_block.dart';

/// A card for connecting an external inference server (Ollama, vLLM, etc.) with
/// Base URL / Model / Advertise-as fields and a Start button. Wraps either a
/// plain [EngineBlock] or a [CollapsibleEngineBlock] depending on [collapsible].
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
    this.blockedReason,
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

  /// Why this computer can't take another engine right now, or null when it
  /// can. The form stays visible and filled in — only Start is held, with the
  /// reason beside it, so the user sees what to stop rather than a card that
  /// vanished.
  final String? blockedReason;

  @override
  ConsumerState<ExternalServerBlock> createState() =>
      _ExternalServerBlockState();
}

class _ExternalServerBlockState extends ConsumerState<ExternalServerBlock> {
  late final _endpoint = TextEditingController(text: widget.initialEndpoint);
  late final _model = TextEditingController(text: widget.initialModel);
  late final _advertise = TextEditingController(text: widget.initialAdvertise);

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
    _model.removeListener(_syncAdvertiseToModel);
    _advertise.removeListener(_markAdvertiseEdited);
    _endpoint.dispose();
    _model.dispose();
    _advertise.dispose();
    super.dispose();
  }

  void _start() {
    ref
        .read(providerRunControllerProvider.notifier)
        .startExternal(
          network: widget.network.networkId,
          endpoint: _endpoint.text.trim(),
          model: _model.text.trim(),
          advertiseAs: _advertise.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final form = ServerForm(
      endpoint: _endpoint,
      model: _model,
      advertise: _advertise,
      suggestedModels: widget.suggestedModels,
      blockedReason: widget.blockedReason,
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

/// The external engine form body: Base URL, Model and Advertise-as fields over a
/// Start button. The controllers stay the source of truth so [onStart] reads
/// them; [suggestedModels] picks the Model field shape.
class ServerForm extends StatelessWidget {
  const ServerForm({
    super.key,
    required this.endpoint,
    required this.model,
    required this.advertise,
    required this.suggestedModels,
    required this.onStart,
    this.blockedReason,
  });

  final TextEditingController endpoint;
  final TextEditingController model;
  final TextEditingController advertise;
  final List<String> suggestedModels;

  /// Why Start is held, as its tooltip. The section says it in prose once, above
  /// these cards — repeating it under every Start would say it three times.
  final String? blockedReason;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledField(
          label: 'Base URL',
          controller: endpoint,
          hint: 'http://localhost:8080/v1',
        ),
        const SizedBox(height: 12),
        ModelField(model: model, suggestedModels: suggestedModels),
        const SizedBox(height: 12),
        AdvertiseAsField(
          controller: advertise,
          hintText: 'qwen3-31b.gguf',
          optional: true,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: Listenable.merge([endpoint, model]),
            builder: (context, _) {
              final empty =
                  endpoint.text.trim().isEmpty || model.text.trim().isEmpty;
              return EngineStartButton(
                label: 'Start engine',
                blockedReason:
                    blockedReason ??
                    (empty ? 'Fill in the Base URL and Model to start.' : null),
                onPressed: onStart,
              );
            },
          ),
        ),
      ],
    );
  }
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
