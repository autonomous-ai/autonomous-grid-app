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
/// "Only clc.fitus.edu.vn" IS the rule. "My domain" is a pronoun the owner has
/// to resolve themselves — and this is the one control where the whole question
/// is *which* domain gets in, so leaving it unsaid is leaving out the answer.
String accessLabelFor(ManagedNetworkType type, {String? domain}) {
  if (type != ManagedNetworkType.domain) return type.label;
  final named = (domain ?? '').trim();
  return named.isEmpty ? type.label : 'Only $named';
}

/// What [type] permits, naming [domain] when there is one — the sentence under
/// the picker, kept in step with [accessLabelFor] so the two cannot disagree.
String accessDescriptionFor(ManagedNetworkType type, {String? domain}) {
  if (type != ManagedNetworkType.domain) return type.description;
  final named = (domain ?? '').trim();
  if (named.isEmpty) return type.description;
  return 'Only people with an @$named email can use this grid — including '
      'anyone added earlier on a different domain.';
}
