import 'api_engine_catalog.dart';
import 'api_engine_choices.dart';
import 'backend_detector.dart';
import 'share_route.dart';

/// One route as the rail draws it: what it is called and one line describing it
/// in terms of what was actually found on this machine.
///
/// A view model rather than three literals in a `build()`, because every line
/// here changes with what the machine has — an engine that still needs
/// installing, which providers this CLI whitelists, whether Ollama is running
/// or merely present. Those are the sentences that go stale silently, so they
/// are built in one tested place (§5).
class ShareRouteOffer {
  const ShareRouteOffer({
    required this.route,
    required this.title,
    required this.line,
    this.detected = 0,
  });

  final ShareRoute route;
  final String title;
  final String line;

  /// Engines found on this machine for this route — only the server route ever
  /// finds any. The count, not a rendering of it: the rail spends it on which
  /// line to write, and the detail pane on how to open its paragraph.
  final int detected;
}

/// The routes this machine can take, in the order the rail shows them.
///
/// A route the machine cannot take is left out rather than drawn disabled: a
/// greyed row still has to be read, and "you can't do this" is not information
/// a first-time reader can act on. The endpoint route is always here — it takes
/// a typed address, so it needs nothing detected to be possible.
List<ShareRouteOffer> buildShareRouteOffers({
  required bool canRunLocal,
  required bool needsSetup,
  required List<ApiEngine> apiEngines,
  required List<DetectedBackend> backends,
}) {
  final keyProviders = keyEngines(apiEngines);
  final external = [
    for (final b in backends)
      if (b.isExternal) b,
  ];
  final running = [
    for (final b in external)
      if (b.running) b,
  ];
  return [
    if (canRunLocal)
      ShareRouteOffer(
        route: ShareRoute.local,
        title: 'Run a model here',
        line: needsSetup
            ? 'Sets up the built-in engine first, then runs a model here.'
            : 'Your own hardware does the work. Weights and prompts never '
                  'leave the machine.',
      ),
    if (keyProviders.isNotEmpty)
      ShareRouteOffer(
        route: ShareRoute.key,
        title: 'Use a key you pay for',
        // Named from what the installed CLI whitelists, never a hopeful list:
        // "your OpenAI key" on a build that serves someone else's is a
        // sentence pointing at a provider this machine cannot reach.
        line: 'Nothing to download. ${apiKeyCardLine(apiEngines)}.',
      ),
    ShareRouteOffer(
      route: ShareRoute.server,
      title: 'Share a server you run',
      detected: external.length,
      line: switch ((running.firstOrNull, external.firstOrNull)) {
        // Running and merely installed are a press apart, and saying the wrong
        // one sends the reader looking for a Start button that is already a
        // Share button, or the reverse.
        (final live?, _) =>
          '${live.label} is already running here. Share it '
              'exactly as it is.',
        (_, final found?) =>
          '${found.label} is installed here. Start it and '
              'share it as it is.',
        _ => 'Point Grid at an engine already running on this computer.',
      },
    ),
  ];
}
