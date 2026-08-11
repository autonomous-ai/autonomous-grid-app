import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';
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

/// How a provider proves it may serve, as data rather than a branch per kind —
/// mirroring the CLI whitelist's own `credential` field.
enum ApiAuth {
  /// A metered API key the user pastes, which the CLI reads from
  /// [ApiProvider.envVar] (ADR 0012 key precedence — the app passes it through
  /// the environment so it never lands on the command line).
  key,

  /// A coding CLI already installed and signed in on this computer, which the
  /// grid drives as an engine behind a loopback server (`credential: "none"` in
  /// the CLI whitelist). There is no key and no browser sign-in: the binary
  /// authenticates itself, and the grid never holds a credential at all.
  localCli,
}

/// Display + wiring metadata for a hosted API provider the app knows how to
/// present. The `grid` CLI carries the model whitelist but not a friendly name,
/// a key hint, or where to get a key — so those live here. [kind] must match the
/// CLI's service kind (`grid join --api <kind>`).
class ApiProvider {
  const ApiProvider({
    required this.kind,
    required this.label,
    required this.auth,
    this.envVar,
    this.keyHint = '',
    this.keyHelpUrl,
    this.binary,
    this.setupUrl,
  });

  final String kind;
  final String label;

  /// What this provider needs before it can serve — see [ApiAuth].
  final ApiAuth auth;

  /// The env var the CLI reads this kind's key from. Null for [ApiAuth.localCli],
  /// which has no credential to pass.
  final String? envVar;
  final String keyHint;
  final String? keyHelpUrl;

  /// The executable a [ApiAuth.localCli] seat drives (`claude`, `codex`), used to
  /// tell "not installed" from "installed but signed out" before the join runs.
  /// Null for a key provider, which names no binary.
  final String? binary;

  /// Where to get [binary] when this computer hasn't got it — the one actionable
  /// next step for a seat the machine can't run yet. Null for a key provider.
  final String? setupUrl;

  /// True when the "engine" is a CLI on this computer rather than a vendor
  /// endpoint ([ApiAuth.localCli]).
  bool get isSeat => auth == ApiAuth.localCli;
}

/// A hosted provider the installed CLI can actually serve, resolved at runtime:
/// its [provider] metadata, the [models] it offers, and whether the credential
/// it needs is already in place, so the block can skip re-asking.
class ApiEngine {
  const ApiEngine({
    required this.provider,
    required this.models,
    required this.lastVerified,
    required this.hasStoredKey,
    this.seatFound,
  });

  final ApiProvider provider;
  final List<ApiEngineModel> models;

  /// ISO date the CLI last checked this whitelist against the vendor's docs
  /// (`last_verified`), surfaced so the freshness of the list is visible. Empty
  /// when the catalog didn't report one.
  final String lastVerified;

  final bool hasStoredKey;

  /// Whether [ApiProvider.binary] is on this computer — **null for a key
  /// provider**, which has no binary to look for. Nullable rather than false so
  /// "no seat here" can't be misread as "the seat is missing".
  ///
  /// Presence only: whether that CLI is *signed in* is the seat's own check, and
  /// duplicating it here would mean hand-copying each CLI's sign-in command and
  /// letting the two drift. A signed-out seat fails the join with the CLI's own
  /// instruction instead (see `_humanizeJoinFailure`).
  final bool? seatFound;
}

/// Advertised model kinds the grid serves through the vendor's `responses`
/// endpoint only. They can't be exercised from the in-app Playground or `grid
/// chat` (which speak chat-completions) — only from an external Codex-style app
/// pointed at the grid (ADR 0015). The UI reads this to stay honest about where
/// a just-served model can be used. Hand-mirrors the CLI whitelist's
/// `endpoints=("responses",)` — the same lockstep the CLI keeps with grid-src.
///
/// Still needed even though this app no longer *joins* a `codex` seat (see
/// [kApiProviders]): the grid is a shared place, so a `codex:*` model can be on
/// it from anyone's machine, and the chat has to route to `/responses` for it.
const Set<String> kResponsesOnlyKinds = {'codex'};

/// Whether [model] is served through the `responses` endpoint only (see
/// [kResponsesOnlyKinds]). Accepts a single advertised name (`codex:gpt-5.5`), a
/// comma-joined list of them, or a bare kind (`codex`) — the shapes
/// `ProviderRunActive.model` can hold — and is true if any names a
/// responses-only kind. Lets the running-engine card swap a dead-end "Try it in
/// Playground" button for honest guidance.
bool isResponsesOnlyModel(String? model) {
  if (model == null || model.isEmpty) return false;
  return model
      .split(',')
      .map((name) => name.trim().split(':').first)
      .any(kResponsesOnlyKinds.contains);
}

/// The CLI-seat kind that serves this computer's Claude Code sign-in.
///
/// Named because two unrelated things key off it: the seat itself, and the loop
/// that claims the grid's distributed coding tasks — those tasks run Claude
/// Code, so they can only ride on this join and on no other.
const String kClaudeSeatKind = 'claude';

/// Hosted providers the app can present. Add one here once its kind lands in the
/// CLI whitelist (`grid catalog --api <kind>`); [apiEnginesProvider] verifies
/// support at runtime, so an entry the installed CLI doesn't know is simply
/// hidden — we never offer a provider a `grid join` would reject.
///
/// The CLI ships `openai` (a pasted API key, ADR 0012) and two **CLI seats** —
/// `claude` and `codex-cli` — which serve a coding CLI already installed here.
/// OpenRouter, Anthropic, Gemini, … are a one-line addition each when their kind
/// is whitelisted.
///
/// The `codex` kind (a ChatGPT subscription signed in over OAuth, ADR 0015) is
/// deliberately **not** here. It answers on `responses` only, so everything the
/// app can do with a model — the Playground, Chat, `grid chat` — was a dead end
/// on it, and the same subscription now serves chat/completions through the
/// `codex-cli` seat. A `codex:*` model can still arrive from someone else's
/// machine on the grid, which is what [isResponsesOnlyModel] still routes.
const List<ApiProvider> kApiProviders = [
  ApiProvider(
    kind: 'openai',
    label: 'OpenAI',
    auth: ApiAuth.key,
    envVar: 'OPENAI_API_KEY',
    keyHint: 'sk-…',
    keyHelpUrl: 'https://platform.openai.com/api-keys',
  ),
  ApiProvider(
    kind: kClaudeSeatKind,
    label: 'Claude Code',
    auth: ApiAuth.localCli,
    binary: 'claude',
    setupUrl: 'https://code.claude.com/docs/en/setup',
  ),
  ApiProvider(
    kind: 'codex-cli',
    label: 'Codex CLI',
    auth: ApiAuth.localCli,
    binary: 'codex',
    setupUrl: 'https://developers.openai.com/codex/cli',
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
    final result = await service.run([
      'catalog',
      '--api',
      provider.kind,
      '--json',
    ]);
    if (!result.ok) continue; // this CLI build doesn't whitelist the kind (yet)
    final catalog = _parseCatalog(result.stdout);
    if (catalog == null || catalog.models.isEmpty) continue;
    engines.add(
      ApiEngine(
        provider: provider,
        models: catalog.models,
        lastVerified: catalog.lastVerified,
        hasStoredKey: storedKinds.contains(provider.kind),
        seatFound: _seatFound(provider),
      ),
    );
  }
  return engines;
});

/// Whether a seat provider's CLI is on this computer — null for a key provider,
/// which names no binary. See [ApiEngine.seatFound].
bool? _seatFound(ApiProvider provider) {
  final binary = provider.binary;
  if (binary == null) return null;
  return HostEnvironment.findExecutable(binary) != null;
}

/// The models + verified-date out of `grid catalog --api <kind> --json`.
/// Lenient: any decode/shape problem yields null so a catalog hiccup hides the
/// provider rather than crashing the Engines tab.
///
/// Only the flat `models` shape, which is what every kind in [kApiProviders]
/// emits. The `codex` kind's per-tier `tiers` map is not read: the app no longer
/// offers that kind, so parsing it was code no catalog could reach. Re-adding
/// codex means re-adding the flatten here — it fails closed (the provider is
/// hidden) rather than silently listing nothing.
({List<ApiEngineModel> models, String lastVerified})? _parseCatalog(
  String stdout,
) {
  try {
    final decoded = jsonDecode(stdout);
    if (decoded is! Map) return null;
    final rows = decoded['models'];
    if (rows is! List) return null;
    final models = _modelsFrom(rows);
    final lastVerified = decoded['last_verified'];
    return (
      models: models,
      lastVerified: lastVerified is String ? lastVerified : '',
    );
  } on FormatException {
    return null;
  }
}

/// Parse the model rows of a catalog list, skipping any non-object row.
List<ApiEngineModel> _modelsFrom(List<dynamic> rows) => [
  for (final model in rows)
    if (model is Map) ApiEngineModel.fromJson(Map<String, dynamic>.from(model)),
];
