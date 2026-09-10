import '../../../shared/panels/panel_tabs.dart';

/// Whether the bottom panel — the strip under the conversation, where the
/// terminal runs — is open.
///
/// Its own flag rather than a mode of the preview panel: the two occupy
/// different edges and are read at the same time, so opening one must never
/// close the other. Unlike that panel it is not remembered per project or
/// across launches (see `kRememberedPanels`): it follows the user between
/// projects and starts shut.
final bottomPanelOpenProvider = panelOpenProvider(PanelHost.bottom);
