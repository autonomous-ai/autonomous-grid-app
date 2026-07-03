import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/grid_overview_provider.dart';
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
  final caps = capabilities.toSet();
  final options = <PlaygroundModelOption>[];
  if (caps.contains(MediaOperation.imageGenerate.capability) ||
      caps.contains(MediaOperation.imageEdit.capability)) {
    options.add(const PlaygroundModelOption(
      id: kImageModeLabel,
      label: kImageModeLabel,
      modality: PlaygroundModality.image,
    ));
  }
  if (caps.contains(MediaOperation.i2v.capability)) {
    options.add(const PlaygroundModelOption(
      id: kVideoModeLabel,
      label: kVideoModeLabel,
      modality: PlaygroundModality.video,
    ));
  }
  return options;
}

/// Everything the Playground can target on the selected grid: its text models
/// (from the model list) plus media modes (from node capabilities). A media mode
/// is only added when the model list doesn't already advertise that modality, so
/// nothing is listed twice.
final playgroundModelsProvider =
    Provider.autoDispose<List<PlaygroundModelOption>>((ref) {
  final textOptions = [
    for (final model in ref.watch(gridModelsProvider))
      PlaygroundModelOption(
        id: model.id,
        label: model.id,
        modality: modalityFromString(model.modality),
      ),
  ];
  final nodes = ref.watch(gridOverviewProvider).asData?.value.nodes ??
      const <OverviewNode>[];
  final capabilities = <String>{for (final node in nodes) ...node.models};
  final existingModalities = textOptions.map((o) => o.modality).toSet();
  final mediaOptions = [
    for (final option in mediaModeOptions(capabilities))
      if (!existingModalities.contains(option.modality)) option,
  ];
  return [...textOptions, ...mediaOptions];
});
