import '../../../shared/panels/panel_metrics.dart';
import '../../../shared/panels/panel_tabs.dart';

/// Whether the preview panel — the work surface beside the conversation — is
/// open.
///
/// The shared panel flag under a name the chat's own files can use without
/// naming a host every time. Deliberately not persisted, and deliberately not
/// per-chat: the panel is a place to *do* something next to whatever you are
/// saying, so it stays open while you move between chats and starts closed in a
/// window you have just opened. The project rail's override sticks because it
/// answers "do I want to see this project's cards"; this one answers "am I
/// working in here right now".
final previewPanelOpenProvider = panelOpenProvider(PanelHost.preview);

/// Whether the preview panel has the whole pane, with the conversation slid out
/// from under it — see [panelExpandedProvider].
final previewPanelExpandedProvider = panelExpandedProvider(PanelHost.preview);
