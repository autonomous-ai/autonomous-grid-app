import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../provider_node/logic/api_engine_catalog.dart';
import '../../network/logic/network_models_provider.dart';
import '../../network/logic/node_display.dart';
import 'chat_message.dart';
import 'playground_request.dart';

/// One selectable option in the Playground model picker: a text model to chat
/// with, or a media mode (image / video) the grid can generate. [id] is what the
/// field holds (a real model id for text; a mode label for media); [modality]
/// decides which endpoint a send hits.
class PlaygroundModelOption {
  const PlaygroundModelOption({
    required this.id,
    required this.label,
    required this.modality,
    this.hosting = ModelHosting.unknown,
  });

  final String id;
  final String label;
  final PlaygroundModality modality;

  /// Where the answer actually comes from — see [ModelHosting].
  final ModelHosting hosting;
}

/// Where a model runs, which is the difference between "a machine on this grid
/// answers you" and "somebody's cloud subscription does".
///
/// It matters more here than in most apps: the whole pitch is models you run
/// yourself, and a grid mixes both kinds in one list under names that give
/// nothing away (`laguna-s-2.1` runs on a 4090 in the room; `codex:gpt-5.5` is
/// relayed to OpenAI). Only the *node* serving a model knows which — `/models`
/// reports every entry the same way — so this is read off the overview's nodes.
enum ModelHosting {
  /// A machine on the grid is running it — the local engine, a connected
  /// server, an image node.
  onGrid,

  /// A node is relaying it to a provider's API on someone's key or subscription.
  cloud,

  /// The virtual router: it picks a model per request, so it is neither until
  /// it has picked.
  routed,

  /// Nothing on the grid claims it, or it claims an engine we don't recognise.
  /// Says nothing rather than guessing — calling a cloud model "on the grid"
  /// promises a privacy it doesn't have.
  unknown,
}

/// Engines that answer from the machine they run on. Everything the app can
/// install or connect, plus the media node.
const _localEngines = {
  'llama.cpp',
  'llamacpp',
  'llama_cpp',
  'ollama',
  'comfyui',
  'vllm',
  'lmstudio',
  // `grid join --at <url>` — someone's own server, still a machine they run.
  'external',
};

/// The relay's `engine` for a node, read as where its models actually run.
///
/// Unrecognised engines stay [ModelHosting.unknown] on purpose: a wrong "runs on
/// the grid" is a privacy claim the app can't back, and a wrong "cloud" libels a
/// machine the user is paying to keep on.
ModelHosting hostingForEngine(String? engine) {
  final name = (engine ?? '').trim().toLowerCase();
  if (name.isEmpty) return ModelHosting.unknown;
  if (_localEngines.contains(name)) return ModelHosting.onGrid;
  if (_cloudEngines.contains(name)) return ModelHosting.cloud;
  return ModelHosting.unknown;
}

/// Engine kinds that relay a prompt to a vendor's API rather than answering from
/// the machine they run on.
///
/// Every provider this app can join, **plus the ones it can't**: a grid is a
/// shared place, so a `codex` seat someone else joined is still on it long after
/// the app stopped offering that kind (see [kApiProviders]). Deriving the mark
/// from our own menu alone quietly relabelled those nodes "unknown" — a privacy
/// answer that got vaguer because a *button* went away.
///
/// A CLI seat counts as cloud too: the process runs here, but the prompt still
/// leaves for Anthropic or OpenAI, which is the only thing this mark is about.
final Set<String> _cloudEngines = {
  for (final provider in kApiProviders) provider.kind,
  ...kResponsesOnlyKinds,
};

/// Where each model on the grid is served from, by asking the online nodes that
/// advertise it. A model served from two places at once (one machine, one cloud
/// relay) reads as [ModelHosting.unknown] — the honest answer to "is this
/// private?" when it depends on which node the relay picks.
///
/// **Keyed by lower-cased id**, and read back the same way, because the two
/// sources disagree on case for the same model: `/models` lists
/// `Qwen3.6-35B-A3B` while the node advertising it says `qwen3.6-35b-a3b`. An
/// exact-string lookup dropped exactly the models a user runs themselves — the
/// one kind this mark exists to point out — and only those, since the hosted
/// ids happen to be lower-case already.
Map<String, ModelHosting> hostingByModel(Iterable<OverviewNode> nodes) {
  final byModel = <String, ModelHosting>{};
  for (final node in nodes) {
    if (!node.online) continue;
    final hosting = hostingForEngine(node.engine);
    for (final id in {node.model, ...node.models}.nonNulls) {
      final key = modelKey(id);
      final seen = byModel[key];
      byModel[key] = seen == null || seen == hosting
          ? hosting
          : ModelHosting.unknown;
    }
  }
  return byModel;
}

/// One model id, in the form the app compares by. See [hostingByModel].
String modelKey(String id) => id.trim().toLowerCase();

/// Labels for the media modes — also the picker field value, so they must not
/// collide with real model ids (they don't: model ids are `maker/name`).
const String kImageModeLabel = 'Image generation';
const String kVideoModeLabel = 'Image → video';

/// Media modes a grid offers, derived from the comfyui [capabilities] its nodes
/// advertise (media capabilities never appear in the model list — they ride on
/// the nodes). Image generate and edit share one "Image" mode (attaching source
/// images switches generate→edit); i2v is the "Video" mode.
List<PlaygroundModelOption> mediaModeOptions(Iterable<String> capabilities) {
  final caps = gridMediaCapabilitiesFrom(capabilities);
  return [
    if (caps.image)
      const PlaygroundModelOption(
        id: kImageModeLabel,
        label: kImageModeLabel,
        modality: PlaygroundModality.image,
      ),
    if (caps.video)
      const PlaygroundModelOption(
        id: kVideoModeLabel,
        label: kVideoModeLabel,
        modality: PlaygroundModality.video,
      ),
  ];
}

/// Everything the Playground can target on a grid: its text models plus the
/// media modes its comfyui [capabilities] offer. A raw `comfyui:*` capability
/// that leaked into [models] is dropped from the text options — you can't drive
/// it as a chat model, so the coded media modes ([mediaModeOptions]) are the
/// only selectable way to test image/video. A media mode is added only when the
/// text models don't already advertise that modality, so nothing is listed
/// twice. Pure so it's unit-tested without a container.
List<PlaygroundModelOption> playgroundOptionsFrom(
  List<OverviewModel> models,
  Iterable<String> capabilities, {
  Map<String, ModelHosting> hosting = const {},
}) {
  final textOptions = [
    for (final model in models)
      if (mediaCapabilityLabel(model.id) == null)
        PlaygroundModelOption(
          id: model.id,
          // The id is what a request carries; the row shows its readable form,
          // so a seat model sits in the list as `claude/opus-5` beside
          // `qwen/qwen3.6-27b` instead of as the relay's `claude:claude-opus-5`.
          label: modelDisplayLabel(model.id),
          modality: modalityFromString(model.modality),
          hosting: modelKey(model.id) == kAutoModelId
              ? ModelHosting.routed
              : hosting[modelKey(model.id)] ?? ModelHosting.unknown,
        ),
  ];
  final existingModalities = textOptions.map((o) => o.modality).toSet();
  final mediaOptions = [
    for (final option in mediaModeOptions(capabilities))
      if (!existingModalities.contains(option.modality)) option,
  ];
  return [...textOptions, ...mediaOptions];
}

/// The selectable options for the currently selected grid — [playgroundOptionsFrom]
/// wired to its live model list and node capabilities.
///
/// The model list is the relay's OpenAI-standard `/models` ([networkModelsProvider]),
/// the canonical list of what the grid serves — so the `auto` auto-routing model
/// shows here too, not just node-advertised engines, unless it is the only entry
/// (a router with nothing behind it reads as no model). The overview supplies
/// what `/models` can't: the comfyui capabilities behind the Image/Video modes,
/// and which engine is behind each model — the only place a cloud relay and a
/// machine in the room can be told apart.
final playgroundModelsProvider =
    Provider.autoDispose<List<PlaygroundModelOption>>((ref) {
      final ids =
          ref.watch(networkModelsProvider).asData?.value ?? const <String>[];
      final nodes =
          ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[];
      return playgroundOptionsFrom(
        [for (final id in ids) OverviewModel(id: id)],
        [for (final node in nodes) ...node.models],
        hosting: hostingByModel(nodes),
      );
    });

/// Whether the option list is still waiting on its **first** answer.
///
/// Both sources are asked, because the options are built from both: one arriving
/// ahead of the other leaves the list legitimately empty for a moment, and
/// gating on that half-loaded state let it read as "no model on this grid".
///
/// A later refresh doesn't count. Both providers flip back to loading on every
/// poll, so reading any loading frame as "not settled" made the no-model state
/// blink off and back on each cadence — on precisely the grid, brand new and
/// still empty, where that screen is the only thing guiding the user.
final playgroundModelsResolvingProvider = Provider.autoDispose<bool>(
  (ref) =>
      ref.watch(gridOverviewProvider.select(awaitingFirstAnswer)) ||
      ref.watch(networkModelsProvider.select(awaitingFirstAnswer)),
);

/// Loading with nothing behind it — as opposed to loading *again*, which still
/// has last round's answer to show.
///
/// The distinction is the difference between "we don't know yet" and "we know,
/// and we're checking again". Anything that hides UI while it waits wants this
/// one, not `isLoading`: on a polled provider `isLoading` comes back true every
/// cadence, forever.
bool awaitingFirstAnswer(AsyncValue<Object?> value) =>
    value.isLoading && !value.hasValue;
