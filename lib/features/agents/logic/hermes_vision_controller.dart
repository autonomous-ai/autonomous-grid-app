import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_vision_policy.dart';
import '../../../shared/copy/setup_hints.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/app_guide_snippets.dart';
import '../../chat/logic/grid_model_catalog.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import 'adapters/hermes_tool.dart';

/// The models on this grid that say they can read an image, **spelled the way
/// the composer's own model picker spells them**.
///
/// Both halves of that sentence are load-bearing.
///
/// `vision == true` only. A model that never said reads as false here, and
/// offering it would be offering a guess — one that fails at the engine several
/// turns later, as an error about a message it can't parse.
///
/// And the *picker's* spelling, because these ids are **sent**, not shown. One
/// model reaches the app under two: `Qwen/Qwen3.8-27B` from the relay's own
/// `/models`, `qwen/qwen3.8-27b` from a node's registration. The app folds case
/// everywhere it *counts* models, so the counts are right — but the folded form
/// is the one the relay will not route. Asked for it, the relay answers `503 No
/// providers available for this model` while that very model is answering
/// beside it under the other spelling. Reading the same catalogue the picker
/// reads ([gridModelCatalogProvider], whose ids come from `/models`) is what
/// keeps the two from disagreeing.
List<String> visionCapableModels(List<PlaygroundModelOption> options) {
  final ids = [
    for (final option in options)
      if (option.vision && option.modality == PlaygroundModality.text)
        option.id,
  ];
  ids.sort();
  return List.unmodifiable(ids);
}

/// The vision-capable models the open grid serves, for the picker.
final visionModelsProvider = Provider<List<String>>(
  (ref) => visionCapableModels([
    for (final group in ref.watch(gridModelCatalogProvider)) ...group.options,
  ]),
);

/// The seam onto Hermes's own auxiliary settings, or null when there is no
/// Hermes on this computer to configure.
final hermesVisionPolicyProvider = Provider<HermesVisionPolicy?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesVisionPolicy();
});

/// Which model Hermes reads images with, as **its own config** says.
///
/// The config is the store: there is no second copy in the app's preferences to
/// drift from it, the choice survives a restart because it was never held in
/// memory, and a config edited by hand in a terminal shows up here as what it
/// is rather than being silently overwritten by a remembered value.
final hermesVisionModelProvider =
    AsyncNotifierProvider<HermesVisionController, String?>(
      HermesVisionController.new,
    );

class HermesVisionController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    return ref.read(hermesVisionPolicyProvider)?.read();
  }

  /// Send image work to [model] on the grid the chat is already using.
  ///
  /// Returns null on success, else a line for the user.
  Future<String?> choose(String model) async {
    final policy = ref.read(hermesVisionPolicyProvider);
    if (policy == null) return _noAgent;
    final network = ref.read(selectedNetworkProvider);
    if (network == null) return _noGrid;
    try {
      // The identity Grid writes its `custom_providers` entry under, so Hermes
      // resolves the model against this grid rather than against a vendor.
      await policy.write(model: model, provider: kHermesGridProviderKey);
    } on Object catch (error) {
      return "Couldn't set the model for images: $error";
    }
    state = AsyncData(model);
    return null;
  }

  /// Hand the choice back to Hermes's own default.
  Future<String?> clear() async {
    final policy = ref.read(hermesVisionPolicyProvider);
    if (policy == null) return _noAgent;
    try {
      await policy.clear();
    } on Object catch (error) {
      return "Couldn't clear the model for images: $error";
    }
    state = const AsyncData(null);
    return null;
  }

  static final _noAgent = notSetUpToMessage('read images');

  static const _noGrid =
      'Open a grid first — the model has to be served by one.';
}
