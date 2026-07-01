import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cli/parsers/download_progress.dart';
import 'models/app_version_info.dart';

/// A failed app-update call. [message] is the friendly, plain-language line for
/// the banner; [detail] carries the raw context (status body, socket error) for
/// the Debug log so an opaque failure isn't just a bare code.
class AppUpdateError {
  const AppUpdateError(this.message, {this.detail});

  final String message;
  final String? detail;
}

/// Seam for the app-update HTTP calls so the controller can be unit-tested
/// offline with a fake. [HttpAppUpdateClient] is the real implementation.
abstract interface class AppUpdateClient {
  /// Fetches the latest-version manifest for [platform] from the control plane.
  /// Returns `(info, null)` on success or `(null, error)` — it never throws.
  Future<(AppVersionInfo?, AppUpdateError?)> check({
    required String apiUrl,
    required String platform,
  });

  /// Streams the installer at [url] into [destination], reporting byte progress
  /// via [onProgress]. [expectedBytes] seeds the progress bar when the server
  /// omits Content-Length. [isCancelled] is polled between chunks so a cancel
  /// aborts promptly. Returns `(file, null)` on success; never throws.
  Future<(File?, AppUpdateError?)> download({
    required String url,
    required File destination,
    int? expectedBytes,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
  });
}

/// Real [AppUpdateClient] — a thin [HttpClient] wrapper mirroring
/// [ManagedNetworkClient]: control-plane calls that return a `(value, error)`
/// tuple instead of throwing, so the controller maps failures to sealed states.
class HttpAppUpdateClient implements AppUpdateClient {
  const HttpAppUpdateClient();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/app/version';

  /// The full version-check URL for [apiUrl] and [platform]. Public so callers
  /// can log the same URL the request hits.
  static Uri endpoint(String apiUrl, String platform) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$_path?platform=${Uri.encodeQueryComponent(platform)}');
  }

  @override
  Future<(AppVersionInfo?, AppUpdateError?)> check({
    required String apiUrl,
    required String platform,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(endpoint(apiUrl, platform));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          AppUpdateError(
            "Couldn't check for updates (error ${response.statusCode}).",
            detail: body,
          ),
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return (
          null,
          const AppUpdateError('The update server returned an unexpected response.'),
        );
      }
      return (AppVersionInfo.fromJson(decoded.cast<String, dynamic>()), null);
    } on TimeoutException {
      return (
        null,
        const AppUpdateError("The update server didn't respond in time.")
      );
    } on SocketException catch (e) {
      return (
        null,
        AppUpdateError("Couldn't reach the update server.", detail: e.message)
      );
    } on Object catch (e) {
      return (null, AppUpdateError("Couldn't check for updates.", detail: '$e'));
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<(File?, AppUpdateError?)> download({
    required String url,
    required File destination,
    int? expectedBytes,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    IOSink? openSink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          AppUpdateError("Couldn't download the update (error ${response.statusCode}).")
        );
      }

      final total =
          response.contentLength > 0 ? response.contentLength : (expectedBytes ?? 0);
      final sink = destination.openWrite();
      openSink = sink;
      var received = 0;
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          await sink.close();
          openSink = null;
          await _deleteQuietly(destination);
          return (null, const AppUpdateError('Update download cancelled.'));
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(_progress(received, total));
      }
      await sink.close();
      openSink = null;
      return (destination, null);
    } on TimeoutException {
      return (
        null,
        const AppUpdateError('The download timed out. Check your connection and try again.')
      );
    } on SocketException catch (e) {
      return (
        null,
        AppUpdateError('The download was interrupted. Try again.', detail: e.message)
      );
    } on Object catch (e) {
      return (null, AppUpdateError("Couldn't download the update.", detail: '$e'));
    } finally {
      await openSink?.close();
      client.close(force: true);
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // A leftover temp file is harmless — the OS reaps its temp dir.
    }
  }

  static DownloadProgress _progress(int received, int total) {
    const bytesPerMb = 1024 * 1024;
    final doneMb = received / bytesPerMb;
    if (total <= 0) return DownloadProgress(doneMb: doneMb);
    return DownloadProgress(
      doneMb: doneMb,
      totalMb: total / bytesPerMb,
      pct: (received / total * 100).clamp(0, 100).toDouble(),
    );
  }
}
