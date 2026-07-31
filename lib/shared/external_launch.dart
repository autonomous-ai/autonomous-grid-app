import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

/// Bring Grid back in front of whatever we sent the user out to.
///
/// The counterpart to [openExternalUrl], and the reliable half of "close the
/// browser when a sign-in finishes". A page **cannot** close its own tab unless
/// a script opened it: an OAuth tab is opened by the OS at the provider's URL,
/// so `window.close()` is refused by every mainstream browser. What always works
/// is raising this window — the browser goes behind, the user is back where the
/// result is, and the leftover tab stops being in the way.
///
/// Best-effort in the same sense as [openExternalUrl]: a window that cannot be
/// raised is not worth failing a completed sign-in over.
Future<void> bringAppToFront() async {
  try {
    // Both, in this order. `focus` alone does nothing for a window that is
    // minimised or hidden to the tray — which is exactly where a user who
    // wandered off mid-sign-in may have left it.
    await windowManager.show();
    await windowManager.focus();
  } on Object {
    // Nothing to say and nowhere useful to say it.
  }
}

/// Open [url] in the user's browser / default handler. Best-effort.
///
/// A local file path (`/Users/…/x.html`) or a schemeless value is opened as a
/// `file://` URI — otherwise the OS has no handler and refuses it (macOS error
/// -50), which is exactly what a bare path used to hit. An `.html` a model just
/// wrote opens in the browser this way, so a game or a page is playable without
/// the user hunting down a path.
Future<void> openExternalUrl(String url) async {
  final uri = _launchableUri(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Uri? _launchableUri(String url) {
  if (url.startsWith('/')) return Uri.file(url);
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  return uri.hasScheme ? uri : Uri.file(url);
}
