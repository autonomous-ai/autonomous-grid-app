import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_project.dart';
import 'code_projects_controller.dart';

/// Who is in a project, and the member key each one is promoted and removed by.
final codeMembersProvider = FutureProvider.autoDispose
    .family<List<ProjectMember>, String>((ref, projectId) async {
      // Watched, not read: switching grids must re-ask rather than keep showing
      // the membership of a project the new grid has never heard of.
      final grid = ref.watch(codeGridIdProvider);
      if (grid == null) {
        throw const CodeGridException('Pick a grid first.');
      }
      final json = await requireCodeCli(
        ref,
      ).object(memberListArgs(projectId: projectId, grid: grid));
      return ProjectMember.listFromJson(json);
    });

/// Admit somebody to a project by email, and hand back their member key.
///
/// They must have **signed in to this grid at least once** first — the relay
/// only knows people it has authenticated — and they must already be on the
/// grid: a project membership for somebody who is not is refused. Only the
/// project's owner may do this.
final addCodeMemberProvider =
    Provider<Future<ProjectMember> Function(String, String)>((ref) {
      return (String projectId, String email) async {
        final json = await requireCodeCli(ref).object(
          memberAddArgs(
            projectId: projectId,
            email: email,
            grid: requireCodeGrid(ref),
          ),
        );
        final member = ProjectMember.fromJson(json);
        if (member == null) {
          throw const CodeGridException(
            'The grid did not confirm who was added. Check the member list '
            'before inviting them again.',
          );
        }
        ref.invalidate(codeMembersProvider(projectId));
        return member;
      };
    });

/// Remove somebody from a project. Takes effect on their very next request.
///
/// Their branch stays where it is, and any member can still promote it — which
/// is the whole reason promote names a member key rather than acting on "yours".
final removeCodeMemberProvider =
    Provider<Future<void> Function(String, String)>((ref) {
      return (String projectId, String memberKey) async {
        await requireCodeCli(ref).object(
          memberRemoveArgs(
            projectId: projectId,
            memberKey: memberKey,
            grid: requireCodeGrid(ref),
          ),
        );
        ref.invalidate(codeMembersProvider(projectId));
      };
    });
