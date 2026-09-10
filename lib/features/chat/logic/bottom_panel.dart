import '../../../shared/panels/panel_tabs.dart';

/// Whether the bottom panel — the strip under the conversation, where the
/// terminal runs — is open.
///
/// Its own flag rather than a mode of the preview panel: the two occupy
/// different edges and are read at the same time, so opening one must never
/// close the other. Remembered per project like that one (see
/// `panelMemoryProvider`): each project keeps its own terminals down here,
/// still running while the user is in another, and gets the strip back as it
/// left it on the next launch.
final bottomPanelOpenProvider = panelOpenProvider(PanelHost.bottom);
