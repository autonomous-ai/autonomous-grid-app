import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/catalog_cache_store.dart';

/// What a catalog read came to, and where it came from.
///
/// [savedAt] is null for a live answer and carries the arrival time when the
/// call failed and the saved copy is what's on screen — the one thing the UI
/// needs to say so out loud. [error] survives beside the saved data on purpose:
/// what failed is still worth logging, and still worth offering a retry for.
typedef CatalogOutcome<T> = ({
  T? data,
  ModelCatalogError? error,
  DateTime? savedAt,
});

/// A catalog read that outlives the catalog: run [fetch], save what came back
/// under [key], and — when it fails — replay the last body saved there through
/// [parse].
///
/// The fallback is deliberately not tried for an expired session: models drawn
/// from a saved copy beside a "sign in to continue" prompt would be offering
/// something the app has just said the user can't have yet.
Future<CatalogOutcome<T>> readCatalog<T>({
  required CatalogCacheStore cache,
  required AppLog log,
  required String key,
  required Future<CatalogRead<T>> Function() fetch,
  required T? Function(String body) parse,
}) async {
  final read = await fetch();
  final body = read.body;
  if (read.error == null && body != null) {
    cache.save(key, body);
    return (data: read.value, error: null, savedAt: null);
  }

  final error = read.error;
  if (error != null && error.sessionExpired) {
    return (data: null, error: error, savedAt: null);
  }

  final saved = cache.read(key);
  final data = saved == null ? null : parse(saved.body);
  if (saved == null || data == null) {
    return (data: null, error: error, savedAt: null);
  }

  // The friendly line the UI shows is never the only record of the failure.
  log.warn(
    'api',
    'Catalog "$key" unavailable — showing the copy saved '
        '${saved.savedAt.toIso8601String()}',
    error: error?.debugDetail,
  );
  return (data: data, error: error, savedAt: saved.savedAt);
}

/// How old a saved copy is, in the words the offline notice uses: "just now",
/// "12 minutes ago", "3 hours ago", "2 days ago". [now] is injectable so the
/// wording is testable without waiting for a clock.
String savedAgoLabel(DateTime savedAt, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(savedAt);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return _ago('minute', elapsed.inMinutes);
  if (elapsed.inHours < 24) return _ago('hour', elapsed.inHours);
  return _ago('day', elapsed.inDays);
}

String _ago(String unit, int count) =>
    '$count ${count == 1 ? unit : '${unit}s'} ago';
