import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';

/// The three control-plane member calls, behind providers so tests can swap in
/// fakes without a real HTTP round-trip. Defaults to the live client — the same
/// seam as [managedNetworkCreateProvider].
typedef MemberListFn =
    Future<(List<ManagedNetworkMember>?, String?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
    });

typedef MemberAddFn =
    Future<(ManagedNetworkMember?, String?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
      required String email,
      required List<String> roles,
    });

typedef MemberRemoveFn =
    Future<(bool, String?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
      required String email,
    });

final memberListFnProvider = Provider<MemberListFn>(
  (ref) => ManagedNetworkClient.listMembers,
);

final memberAddFnProvider = Provider<MemberAddFn>(
  (ref) => ManagedNetworkClient.addMember,
);

final memberRemoveFnProvider = Provider<MemberRemoveFn>(
  (ref) => ManagedNetworkClient.removeMember,
);

/// Thrown by [networkMembersProvider] so the Members tab renders a clean message
/// instead of a raw socket error (mirrors `GridOverviewUnavailable`).
class MembersUnavailable implements Exception {
  const MembersUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Active members of the grid [networkId], via the control-plane list endpoint.
/// Auto-disposes and refetches when the grid changes; `ref.invalidate` it after
/// an add/remove to refresh.
final networkMembersProvider = FutureProvider.autoDispose
    .family<List<ManagedNetworkMember>, String>((ref, networkId) async {
      final token = ref.watch(sessionProvider).sessionToken;
      if (token == null || token.isEmpty) {
        throw const MembersUnavailable('Sign in to manage members.');
      }
      final apiUrl = ref.read(gridApiUrlProvider);
      final log = ref.read(commandLogProvider.notifier);
      final logId = log.begin(
        CliCallKind.http,
        'GET ${ManagedNetworkClient.membersEndpoint(apiUrl, networkId)}',
        detail: const CommandDetail(authorized: true),
      );
      final (members, error) = await ref.read(memberListFnProvider)(
        apiUrl: apiUrl,
        sessionToken: token,
        networkId: networkId,
      );
      log.finish(logId, exitCode: error == null ? 200 : null, error: error);
      if (members == null) {
        throw MembersUnavailable(error ?? 'Could not load members.');
      }
      return members;
    });

/// How many people are on the selected grid — the top bar's member figure.
///
/// Null until the roster resolves, and null forever on a grid whose members the
/// control plane won't hand over (signed out, or a grid it doesn't host): the
/// pill drops the figure rather than showing a `0` that would read as "nobody is
/// on this grid" when the truth is "we didn't get to ask".
///
/// Shares [networkMembersProvider]'s cache with the Members tab, so opening that
/// tab costs no second request and an add/remove there moves this count too.
///
/// Reads `.value`, not `.asData`: an invalidate (the Members tab refreshing after
/// an add) puts the roster back into a loading state that `asData` reports as
/// nothing, which would blink the figure out of the pill — and out from under the
/// panel anchored to it — for the length of one request.
final selectedGridMemberCountProvider = Provider.autoDispose<int?>((ref) {
  final grid = ref.watch(selectedNetworkProvider);
  if (grid == null) return null;
  return ref.watch(networkMembersProvider(grid.networkId)).value?.length;
});

/// Add/remove a member through the control plane, logging the HTTP call to the
/// Debug tab (like [CreateNetworkController]) and returning a user-facing error
/// message, or `null` on success. The caller invalidates [networkMembersProvider]
/// to refresh the list. Exposed as functions so the dialog/row keep only their
/// own ephemeral in-flight state.
typedef AddMemberAction =
    Future<String?> Function({
      required String networkId,
      required String email,
      required List<String> roles,
    });

typedef RemoveMemberAction =
    Future<String?> Function({
      required String networkId,
      required String email,
    });

final addMemberActionProvider = Provider<AddMemberAction>((ref) {
  return ({
    required String networkId,
    required String email,
    required List<String> roles,
  }) async {
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) return 'Sign in to manage members.';
    final apiUrl = ref.read(gridApiUrlProvider);
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'POST ${ManagedNetworkClient.membersEndpoint(apiUrl, networkId)}',
      detail: CommandDetail.json(
        ManagedNetworkClient.addMemberBody(email, roles),
        authorized: true,
      ),
    );
    final (member, error) = await ref.read(memberAddFnProvider)(
      apiUrl: apiUrl,
      sessionToken: token,
      networkId: networkId,
      email: email,
      roles: roles,
    );
    log.finish(logId, exitCode: error == null ? 200 : null, error: error);
    return error;
  };
});

final removeMemberActionProvider = Provider<RemoveMemberAction>((ref) {
  return ({required String networkId, required String email}) async {
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) return 'Sign in to manage members.';
    final apiUrl = ref.read(gridApiUrlProvider);
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'DELETE ${ManagedNetworkClient.memberEndpoint(apiUrl, networkId, email)}',
      detail: const CommandDetail(authorized: true),
    );
    final (ok, error) = await ref.read(memberRemoveFnProvider)(
      apiUrl: apiUrl,
      sessionToken: token,
      networkId: networkId,
      email: email,
    );
    log.finish(logId, exitCode: ok ? 200 : null, error: error);
    return error;
  };
});
