/// One advisor in the auto-router chain: a `provider[:model]` pair the router
/// consults to rank the grid's models for a request. Picked by name from the
/// platform catalog — it carries no key or URL (the platform holds those).
class Advisor {
  const Advisor({required this.provider, this.model});

  final String provider;

  /// The catalog model, or null for a bare provider (the catalog default).
  final String? model;

  /// The `provider[:model]` token the CLI expects — bare provider when no model.
  String get token => model == null ? provider : '$provider:$model';

  factory Advisor.fromJson(Map<String, dynamic> json) {
    final rawModel = json['model'];
    final model = rawModel is String && rawModel.trim().isNotEmpty
        ? rawModel.trim()
        : null;
    return Advisor(provider: (json['provider'] ?? '').toString(), model: model);
  }
}

/// A grid's auto-routing config: whether the reserved `auto` model is on, and
/// the ordered advisor chain that ranks candidates for each request. Mirrors
/// `grid router status --json` (`{enabled, advisors:[{provider, model}]}`) — no
/// keys or URLs, which the CLI masks out (ADR 0013).
class AutoRouterConfig {
  const AutoRouterConfig({required this.enabled, required this.advisors});

  final bool enabled;
  final List<Advisor> advisors;

  bool get hasAdvisors => advisors.isNotEmpty;

  factory AutoRouterConfig.fromJson(Map<String, dynamic> json) =>
      AutoRouterConfig(
        enabled: json['enabled'] == true,
        advisors: [
          for (final entry in (json['advisors'] as List? ?? const []))
            if (entry is Map)
              Advisor.fromJson(Map<String, dynamic>.from(entry)),
        ],
      );
}

/// One provider in the advisor catalog: its whitelisted models and which one is
/// the default (used when an advisor names the provider without a model).
class AdvisorProvider {
  const AdvisorProvider({
    required this.provider,
    required this.defaultModel,
    required this.models,
  });

  final String provider;
  final String? defaultModel;
  final List<String> models;

  factory AdvisorProvider.fromJson(Map<String, dynamic> json) =>
      AdvisorProvider(
        provider: (json['provider'] ?? '').toString(),
        defaultModel: json['default_model'] is String
            ? json['default_model'] as String
            : null,
        models: json['models'] is List
            ? (json['models'] as List).map((e) => e.toString()).toList()
            : const [],
      );
}

/// The platform advisor catalog (`grid router models --json`) — every provider
/// and its selectable models. Fed to the advisor picker so the chain is chosen
/// by name, never typed.
class AdvisorCatalog {
  const AdvisorCatalog(this.providers);

  final List<AdvisorProvider> providers;

  /// Every advisor the catalog offers, flattened to `provider:model` tokens in
  /// catalog order — the options the picker lists.
  List<String> get allTokens => [
    for (final provider in providers)
      for (final model in provider.models) '${provider.provider}:$model',
  ];

  factory AdvisorCatalog.fromJson(Map<String, dynamic> json) => AdvisorCatalog([
    for (final entry in (json['providers'] as List? ?? const []))
      if (entry is Map)
        AdvisorProvider.fromJson(Map<String, dynamic>.from(entry)),
  ]);
}
