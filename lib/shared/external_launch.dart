import 'package:url_launcher/url_launcher.dart';

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
