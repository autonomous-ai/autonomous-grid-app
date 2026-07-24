import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
import '../../network/logic/node_display.dart';
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
  });

  final String id;
  final String label;
  final PlaygroundModality modality;
}

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
  Iterable<String> capabilities,
) {
  final textOptions = [
    for (final model in models)
      if (mediaCapabilityLabel(model.id) == null)
        PlaygroundModelOption(
          id: model.id,
          label: model.id,
          modality: modalityFromString(model.modality),
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
/// (a router with nothing behind it reads as no model). The overview is read only
/// for the node comfyui capabilities behind the Image/Video modes (those never
/// appear in `/models`).
final playgroundModelsProvider =
    Provider.autoDispose<List<PlaygroundModelOption>>((ref) {
      final ids =
          ref.watch(networkModelsProvider).asData?.value ?? const <String>[];
      final nodes =
          ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[];
      return playgroundOptionsFrom(
        [for (final id in ids) OverviewModel(id: id)],
        [for (final node in nodes) ...node.models],
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
