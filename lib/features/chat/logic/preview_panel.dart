import '../../../shared/panels/panel_metrics.dart';
import '../../../shared/panels/panel_tabs.dart';

/// Whether the preview panel — the work surface beside the conversation — is
/// open.
///
/// The shared panel flag under a name the chat's own files can use without
/// naming a host every time. Not per chat — it stays open while you move
/// between the chats of one project — but per project, and remembered across
/// launches with the tabs in it: see `panelMemoryProvider`.
final previewPanelOpenProvider = panelOpenProvider(PanelHost.preview);

/// Whether the preview panel has the whole pane, with the conversation slid out
/// from under it — see [panelExpandedProvider].
final previewPanelExpandedProvider = panelExpandedProvider(PanelHost.preview);
