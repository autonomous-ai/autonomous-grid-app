import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';

/// The `GET /v1/grid/me` probe, behind a provider so tests can swap in a fake.
typedef GridDomainFn =
    Future<(String?, String?)> Function({
      required String apiUrl,
      required String sessionToken,
    });

final gridDomainFnProvider = Provider<GridDomainFn>(
  (ref) => ManagedNetworkClient.canRestrictToDomain,
);

/// The email domain this account may gate a grid by, or null when it may not.
///
/// The control plane decides (`user.can_restrict_to_domain` / `user.email_domain`),
/// because the list of public providers that cannot — gmail.com and friends,
/// where "only my domain" would mean *all of Gmail* — is a server env var.
/// Keeping a copy here would drift, and the drift is silent in the worst
/// direction: the app keeps offering a rule the API has started refusing.
///
/// Null while loading and on any error. A missing option is a small loss; an
/// option that 400s after the person has committed to it is a dead end they
/// cannot tell from a bug.
final gridDomainProvider = FutureProvider.autoDispose<String?>((ref) async {
  final token = ref.watch(sessionProvider).sessionToken;
  if (token == null || token.isEmpty) return null;
  final (domain, error) = await ref.read(gridDomainFnProvider)(
    apiUrl: ref.read(gridApiUrlProvider),
    sessionToken: token,
  );
  if (error != null) return null;
  return domain;
});

/// The access rules to offer, given whether the domain rule is available.
///
/// Pure so it can be tested without a server: the decision is small but it is
/// the difference between a form that works and one that offers a choice the
/// API rejects.
List<ManagedNetworkType> accessTypesFor({required bool canRestrictToDomain}) {
  if (canRestrictToDomain) return ManagedNetworkType.values;
  // Filtered out, not disabled: a greyed cell invites "why not?", and the honest
  // answer ("your email provider is public, so this rule would let in everyone
  // who uses it") is longer than the control.
  return ManagedNetworkType.values
      .where((t) => t != ManagedNetworkType.domain)
      .toList();
}

/// What to call [type] in a picker, naming [domain] when there is one.
///
/// "Only @clc.fitus.edu.vn emails" IS the rule. "My domain" is a pronoun the
/// owner has to resolve themselves — and this is the one control where the
/// whole question is *which* domain gets in, so leaving it unsaid is leaving
/// out the answer.
///
/// [domain] is the **signed-in account's** email domain (`email_domain` from
/// `GET /v1/grid/me`), not the grid's. They agree for an owner setting the rule
/// on their own grid, which is the only case that can reach the picker — but a
/// grid already gated to some other domain carries it in `access_domain`, a
/// field the app never receives (it is on `GET /managed-networks/{id}`, which
/// the app does not call, and absent from `credentials.toml`). Read the label
/// as "the domain this account can gate by", and see `gatedDomainFor` for the
/// one case the app CAN name exactly.
String accessLabelFor(ManagedNetworkType type, {String? domain}) {
  if (type != ManagedNetworkType.domain) return type.label;
  final named = (domain ?? '').trim();
  // "@" and the plural, because the bare form — "Only autonomous.ai" — names
  // something rather than describing a rule, and Grid has an object by exactly
  // that name: an account whose email domain is autonomous.ai also has a
  // **grid** called autonomous.ai in the same sidebar. On a grid called
  // Test-Grid the label read as "this grid is now that other grid". Addresses
  // are what the rule gates, so the label says addresses.
  //
  // No "Only": since 2026-08-21 the domain ADMITS rather than excludes, and
  // the people invited from other domains keep working beside it (01653659).
  // "Only @x emails" would be a promise the gate stopped making that morning.
  return named.isEmpty ? type.label : '@$named emails';
}

/// What [type] permits, naming [domain] when there is one — the sentence under
/// the picker, kept in step with [accessLabelFor] so the two cannot disagree.
String accessDescriptionFor(ManagedNetworkType type, {String? domain}) {
  if (type != ManagedNetworkType.domain) return type.description;
  final named = (domain ?? '').trim();
  if (named.isEmpty) return type.description;
  return 'Anyone with an @$named email can use this grid, or run a model for '
      'it — as well as the people you invite.';
}

/// The one-line explanation printed **inside the share sheet's access row**,
/// under the rule's own name.
///
/// Shorter than [accessDescriptionFor], and deliberately: Google Drive's sheet
/// carries exactly one sentence of explanation, sitting under the rule in the
/// row rather than inside the menu, and it points at what the reader can see —
/// "only people with access", i.e. the list directly above it. The menu itself
/// is labels and a tick. That split is what keeps the sentence from arriving
/// clipped: a row is as wide as the dialog, a menu is as wide as its button.
///
/// [ManagedNetworkType.description] stays as it is — the create-grid screens
/// print it before any list of people exists, so it cannot say "listed above".
String accessRowDescription(ManagedNetworkType type, {String? domain}) {
  switch (type) {
    case ManagedNetworkType.restricted:
      return 'Only the people listed above can use this grid, or run a model '
          'for it.';
    case ManagedNetworkType.domain:
      final named = (domain ?? '').trim();
      if (named.isEmpty) return type.description;
      // Two clauses, both load-bearing. "or run a model for it" is not
      // padding — a domain account is admitted as a **`both`** member, not as
      // a consumer: `list_grid_members` turns every account on the gated
      // domain into a synthetic member with the `both` roles and
      // `source: domain` (`grid_networks/store.py`). And "as well as the
      // people you invite" is the half that changed on 2026-08-21: the domain
      // now admits rather than excludes, so an invited outsider keeps working
      // after the switch (01653659).
      return 'Anyone with an @$named email can use this grid, or run a model '
          'for it — as well as the people you invite.';
    case ManagedNetworkType.anyone:
      // The second clause is never dropped: opening up who may *use* the grid
      // is not opening up who may plug a machine into it, and "anyone can use
      // this grid" alone reads as the larger promise.
      return 'Anyone signed in to Grid can use it. Only the people above can '
          'run a model for it.';
  }
}

/// What switching to [target] TAKES — the half of a permission change nobody
/// expects, and the reason this one is confirmed before it runs.
///
/// The restart is not in here: every rule restarts the grid, so the warning
/// says it once ([accessChangeWarning]) rather than three times over.
String accessCostFor(ManagedNetworkType target) => switch (target) {
  ManagedNetworkType.restricted =>
    'Anyone using it who is not on the list above loses access, and any model '
        'they run for it stops serving.',
  // This used to warn that everyone off the domain lost access "even though
  // they stay on the list". They do not any more — the domain admits, and the
  // list keeps working beside it — so the cost falls only on someone who is on
  // neither, which is who a switch away from "Anyone" takes it from.
  ManagedNetworkType.domain =>
    'Anyone using it who is neither on that domain nor on the list above '
        'loses access, and any model they run for it stops serving.',
  ManagedNetworkType.anyone =>
    'Usage on this grid stops being billed, and you can no longer block an '
        'individual person.',
};

/// The whole warning shown while a change is picked but not yet saved.
///
/// Names what is lost rather than asking "are you sure?" — the question adds
/// no information the reader didn't already have, and trains people to dismiss
/// it. The restart leads because it is the part that hits everyone on the grid,
/// including the person reading.
String accessChangeWarning(ManagedNetworkType target, {String? domain}) {
  final name = accessLabelFor(target, domain: domain);
  return 'Switching to “$name” restarts this grid — everyone reconnects once. '
      '${accessCostFor(target)}';
}
