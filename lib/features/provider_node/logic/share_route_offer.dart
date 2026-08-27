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
        title: 'Run a local model',
        line: needsSetup
            ? 'Sets up the built-in engine first, then runs a model here.'
            : 'Your own hardware does the work. Weights and prompts never '
                  'leave the machine.',
      ),
    if (keyProviders.isNotEmpty)
      ShareRouteOffer(
        route: ShareRoute.key,
        // "Frontier" is a word §5 would normally send back — and the line
        // under it explains the term by example, which is what that rule
        // actually asks for: a reader who does not know it meets "OpenAI" one
        // line down and does.
        title: 'Share frontier models via your API key',
        // The provider is named from what the installed CLI whitelists, never
        // a hopeful list: "your OpenAI key" on a build that serves someone
        // else's points at a provider this machine cannot reach. The cost sits
        // here rather than in the title, because what it costs is a
        // consequence of the route rather than the name of it — and a reader
        // choosing between three cards should meet it before pressing, not in
        // the pane afterwards.
        line:
            'Nothing to download. ${apiKeyCardLine(apiEngines)}, and pay for '
            'what the grid uses.',
      ),
    ShareRouteOffer(
      route: ShareRoute.server,
      // The verb is about the route, not about the moment: on the common
      // machine the engine is installed and stopped, which is exactly what
      // this starts. The line under it carries the state, so a server already
      // running is never told to start again.
      title: 'Start an engine you already have',
      detected: external.length,
      line: switch ((running.firstOrNull, external.firstOrNull)) {
        // Running and merely installed are a press apart, and saying the wrong
        // one sends the reader looking for a Start button that is already a
        // Share button, or the reverse.
        (final live?, _) =>
          '${live.label} is running here. Point Grid at it and share it '
              'exactly as it is.',
        (_, final found?) =>
          '${found.label} is installed here. Start it and '
              'share it as it is.',
        _ => 'Point Grid at any OpenAI-compatible engine on this computer.',
      },
    ),
  ];
}
