import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/catalog_cache_store.dart';
import '../../auth/logic/session_controller.dart';
import 'catalog_fallback.dart';

/// This machine's hardware profile from `grid device-info --json`, forwarded
/// verbatim to the catalog API (the doc: the app doesn't interpret the fields,
/// it hands the object straight up). Null when the CLI is missing or the probe
/// fails — the suggest flow then reports the device couldn't be read.
final deviceInfoProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final service = ref.watch(gridCliServiceProvider);
  if (service == null) return null;
  final result = await service.run(const ['device-info', '--json']);
  if (!result.ok) return null;
  try {
    final decoded = jsonDecode(result.stdout);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
});

/// The outcome of asking the catalog what to run on this machine — one sealed
/// case per state the "Suggested for your device" section renders, so the widget
/// switches exhaustively instead of juggling null + bool + error.
sealed class SuggestOutcome {
  const SuggestOutcome();
}

/// The catalog ranked models for this device, best-first. Empty when nothing fits.
///
/// [savedAt] is set only when the catalog couldn't be reached and these are the
/// picks saved from an earlier run — the section says so rather than passing an
/// old ranking off as today's.
class SuggestReady extends SuggestOutcome {
  const SuggestReady({required this.ranked, this.savedAt});
  final List<CatalogModelPick> ranked;
  final DateTime? savedAt;
}

/// No stored session token — the catalog needs the user signed in.
class SuggestSignInRequired extends SuggestOutcome {
  const SuggestSignInRequired();
}

/// The catalog ran but nothing fits this machine (the `repo_id: null` sentinel).
class SuggestNoMatch extends SuggestOutcome {
  const SuggestNoMatch();
}

/// The catalog couldn't be reached or read ([reason] is the friendly line) and
/// nothing was saved to fall back on — the section drops to the offline
/// `grid catalog` list.
class SuggestUnavailable extends SuggestOutcome {
  const SuggestUnavailable(this.reason);
  final String reason;
}

/// The suggest call, injectable so the provider is unit-testable without the
/// network (tests override it with a fake; production calls the real client).
typedef CatalogSuggestFn =
    Future<CatalogRead<CatalogSuggestion>> Function({
      required String apiUrl,
      required String sessionToken,
      required Map<String, dynamic> device,
    });

final catalogSuggestFnProvider = Provider<CatalogSuggestFn>(
  (ref) => ModelCatalogClient.suggest,
);

/// Device-aware model suggestions for the model manager: read the session token,
/// probe the hardware, and ask `POST /v1/grid/catalog` for the ranked picks.
/// Every failure maps to a [SuggestOutcome] the UI can act on rather than an
/// exception — signed-out, no-match, and unreachable are all normal states here.
///
/// A reachable catalog is also saved, so an unreachable one falls back to those
/// picks instead of an empty section (see [readCatalog]).
final suggestedCatalogProvider = FutureProvider<SuggestOutcome>((ref) async {
  final token = ref.watch(sessionProvider).sessionToken;
  if (token == null || token.isEmpty) {
    return const SuggestSignInRequired();
  }

  final device = await ref.watch(deviceInfoProvider.future);
  if (device == null) {
    return const SuggestUnavailable("Couldn't read this computer's details.");
  }

  final apiUrl = ref.watch(gridApiUrlProvider);
  final suggest = ref.watch(catalogSuggestFnProvider);
  final outcome = await readCatalog<CatalogSuggestion>(
    cache: ref.watch(catalogCacheStoreProvider),
    log: ref.read(appLogProvider),
    key: catalogSuggestKey(apiUrl),
    fetch: () => suggest(apiUrl: apiUrl, sessionToken: token, device: device),
    parse: parseSuggestResponse,
  );

  final suggestion = outcome.data;
  if (suggestion == null) {
    return switch (outcome.error) {
      ModelCatalogError(sessionExpired: true) => const SuggestSignInRequired(),
      ModelCatalogError(:final message) => SuggestUnavailable(message),
      _ => const SuggestNoMatch(),
    };
  }

  final ranked = suggestion.models.where((m) => m.hasModel).toList();
  if (ranked.isEmpty) return const SuggestNoMatch();
  return SuggestReady(ranked: ranked, savedAt: outcome.savedAt);
});
