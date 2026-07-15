import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/grid_overview_provider.dart';
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
final playgroundModelsProvider =
    Provider.autoDispose<List<PlaygroundModelOption>>((ref) {
      final nodes =
          ref.watch(gridOverviewProvider).asData?.value.nodes ??
          const <OverviewNode>[];
      return playgroundOptionsFrom(ref.watch(gridModelsProvider), [
        for (final node in nodes) ...node.models,
      ]);
    });
