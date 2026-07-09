import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';

/// One model an API engine can serve, from the CLI's static whitelist
/// (`grid catalog --api <kind> --json`). The whitelist is curated data — no key
/// or network needed to read it — so the block can list what a provider offers
/// before the user commits a key. [advertised] is the grid-facing name
/// (`openai:gpt-5.5`); [vendorName] is the plain model id shown to the user.
class ApiEngineModel {
  const ApiEngineModel({
    required this.advertised,
    required this.vendorName,
    required this.contextWindow,
    required this.supportsTools,
    required this.supportsVision,
    required this.notes,
  });

  final String advertised;
  final String vendorName;
  final int contextWindow;
  final bool supportsTools;
  final bool supportsVision;
  final String notes;

  factory ApiEngineModel.fromJson(Map<String, dynamic> json) => ApiEngineModel(
        advertised: json['advertised'] as String,
        vendorName: json['vendor_name'] as String? ?? json['advertised'] as String,
        contextWindow: (json['context_window'] as num?)?.toInt() ?? 0,
        supportsTools: json['supports_tools'] as bool? ?? false,
        supportsVision: json['supports_vision'] as bool? ?? false,
        notes: json['notes'] as String? ?? '',
      );
}

/// Display + wiring metadata for a hosted API provider the app knows how to
/// present. The `grid` CLI carries the model whitelist but not a friendly name,
/// a key hint, or where to get a key — so those live here. [kind] must match the
/// CLI's service kind (`grid join --api <kind>`); [envVar] is the environment
/// variable the CLI reads the key from (ADR 0012 key precedence — the app passes
/// the key that way so it never lands on the command line).
class ApiProvider {
  const ApiProvider({
    required this.kind,
    required this.label,
    required this.envVar,
    required this.keyHint,
    this.keyHelpUrl,
  });

  final String kind;
  final String label;
  final String envVar;
  final String keyHint;
  final String? keyHelpUrl;
}

/// A hosted provider the installed CLI can actually serve, resolved at runtime:
/// its [provider] metadata, the [models] it offers, and whether a key is already
/// saved on this machine ([hasStoredKey]) so the block can skip re-asking.
class ApiEngine {
  const ApiEngine({
    required this.provider,
    required this.models,
    required this.lastVerified,
    required this.hasStoredKey,
  });

  final ApiProvider provider;
  final List<ApiEngineModel> models;

  /// ISO date the CLI last checked this whitelist against the vendor's docs
  /// (`last_verified`), surfaced so the freshness of the list is visible. Empty
  /// when the catalog didn't report one.
  final String lastVerified;

  final bool hasStoredKey;
}

/// Hosted providers the app can present. Add one here once its kind lands in the
/// CLI whitelist (`grid catalog --api <kind>`); [apiEnginesProvider] verifies
/// support at runtime, so an entry the installed CLI doesn't know is simply
/// hidden — we never offer a provider a `grid join` would reject.
///
/// Today the CLI ships only `openai` (ADR 0012, Slice 1). OpenRouter, Anthropic,
/// Gemini, … are a one-line addition each when their kind is whitelisted.
const List<ApiProvider> kApiProviders = [
  ApiProvider(
    kind: 'openai',
    label: 'OpenAI',
    envVar: 'OPENAI_API_KEY',
    keyHint: 'sk-…',
    keyHelpUrl: 'https://platform.openai.com/api-keys',
  ),
];

/// The hosted providers the installed CLI can serve right now, each with its
/// model whitelist and stored-key status. For every known [kApiProviders] entry
/// it reads `grid catalog --api <kind> --json` (static data — no key, no vendor
/// call) and keeps the ones the CLI supports. Empty when `grid` is absent or no
/// known provider is whitelisted — the block hides itself in that case.
final apiEnginesProvider = FutureProvider<List<ApiEngine>>((ref) async {
  final service = ref.watch(gridCliServiceProvider);
  if (service == null) return const [];
  final storedKinds = ref.watch(gridHomeStoreProvider).storedApiKinds();

  final engines = <ApiEngine>[];
  for (final provider in kApiProviders) {
    final result =
        await service.run(['catalog', '--api', provider.kind, '--json']);
    if (!result.ok) continue; // this CLI build doesn't whitelist the kind (yet)
    final catalog = _parseCatalog(result.stdout);
    if (catalog == null || catalog.models.isEmpty) continue;
    engines.add(ApiEngine(
      provider: provider,
      models: catalog.models,
      lastVerified: catalog.lastVerified,
      hasStoredKey: storedKinds.contains(provider.kind),
    ));
  }
  return engines;
});

/// The models + verified-date out of `grid catalog --api <kind> --json`.
/// Lenient: any decode/shape problem yields null so a catalog hiccup hides the
/// provider rather than crashing the Engines tab.
({List<ApiEngineModel> models, String lastVerified})? _parseCatalog(
    String stdout) {
  try {
    final decoded = jsonDecode(stdout);
    if (decoded is! Map) return null;
    final rawModels = decoded['models'];
    if (rawModels is! List) return null;
    final models = [
      for (final model in rawModels)
        if (model is Map) ApiEngineModel.fromJson(Map<String, dynamic>.from(model)),
    ];
    final lastVerified = decoded['last_verified'];
    return (
      models: models,
      lastVerified: lastVerified is String ? lastVerified : '',
    );
  } on FormatException {
    return null;
  }
}
