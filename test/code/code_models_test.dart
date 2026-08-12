import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_project.dart';
import 'package:grid_app/features/code/logic/code_task.dart';
import 'package:grid_app/features/code/logic/code_write_results.dart';
import 'package:grid_app/features/code/logic/integration.dart';
import 'package:grid_app/features/code/logic/project_status.dart';

void main() {
  group('a reply the app cannot read is never reported as a result', () {
    test('an integration with no status is refused, not shown as success', () {
      // Printing the success line by default is how a body a proxy had
      // stripped once told a team their work had landed — and the next thing
      // somebody does on that belief is publish.
      expect(IntegrationResult.fromJson({'branch': 'wip/a'}), isNull);
    });

    test(
      'a fast-forward with no commit is refused — that is its whole payload',
      () {
        expect(
          IntegrationResult.fromJson({
            'status': 'fast_forward',
            'branch': 'wip/a',
          }),
          isNull,
        );
      },
    );

    test(
      'a merge task with no task id leaves nothing to watch, so it is refused',
      () {
        expect(
          IntegrationResult.fromJson({
            'status': 'merge_task',
            'branch': 'wip/a',
          }),
          isNull,
        );
      },
    );

    test('a promote that will not say whether main moved is not a release', () {
      // Tri-state on purpose: absent is "the relay did not answer", which is a
      // different thing from "nothing moved".
      expect(PromoteResult.fromJson({'branch': 'main'}), isNull);
      expect(
        PromoteResult.fromJson({'branch': 'main', 'advanced': false})?.advanced,
        isFalse,
      );
    });

    test('an import that does not say "imported" leaves the project empty', () {
      expect(ImportResult.fromJson({'commit': 'a' * 40}), isNull);
      expect(
        ImportResult.fromJson({
          'status': 'imported',
          'commit': 'a' * 40,
        })?.trunk,
        'main',
      );
    });

    test('a cancel that will not name the new state is not a cancellation', () {
      expect(CancelResult.fromJson({'error': 'cancelled'}), isNull);
    });

    test(
      'a status with no branch is not a status — blanks read as "no work"',
      () {
        expect(ProjectStatus.fromJson({'project_id': 'P1'}), isNull);
        expect(ProjectStatus.isReadable({'project_id': 'P1'}), isFalse);
      },
    );

    test('an empty task list is a real answer, a missing one is not', () {
      // Checked on presence, not truthiness: somebody polling a shared project
      // was once told nobody was working because a proxy stripped the body.
      expect(TaskPage.carriesTasks({'tasks': <dynamic>[]}), isTrue);
      expect(TaskPage.carriesTasks(<String, dynamic>{}), isFalse);
    });
  });

  group('project status', () {
    final status = ProjectStatus.fromJson({
      'project_id': 'P1',
      'member_key': 'def456',
      'trunk': 'main',
      'main_commit': 'a' * 40,
      'branch': 'wip/def456',
      'wip_commit': 'b' * 40,
      'ahead': 3,
      'behind': 2,
      'can_promote': false,
      'active_task': {'id': 't-9', 'state': 'running'},
      'queue': {'queued': 2, 'running': 1},
      'providers': {'online': 2, 'paused': 1, 'serves_you': true},
    })!;

    test(
      'carries the id of whatever holds the slot, or there is nothing to wait on',
      () {
        expect(status.slotHolder?.id, 't-9');
        expect(status.slotHolder?.state, TaskState.running);
      },
    );

    test('keeps the relay’s own promote verdict rather than deriving one', () {
      // Deriving `behind == 0` here would put the rule in a second place, free
      // to disagree about a fact only the relay can see.
      expect(status.canPromote, isFalse);
    });

    test(
      'a missing distance is absent, never zero — 0/0 reads as up to date',
      () {
        final fresh = ProjectStatus.fromJson({
          'project_id': 'P1',
          'branch': 'wip/def456',
        })!;
        expect(fresh.ahead, isNull);
        expect(fresh.hasNothingYet, isTrue);
      },
    );

    test('no trunk commit means nobody has imported a repository yet', () {
      final empty = ProjectStatus.fromJson({
        'project_id': 'P1',
        'branch': 'wip/def456',
      })!;
      expect(empty.needsImport, isTrue);
      expect(status.needsImport, isFalse);
    });

    test('a distance nobody can compute is never reported as "up to date"', () {
      // The line above the transcript is the only place this is said. `0 / 0`
      // there reads as "you are level with the team", and the next thing
      // somebody does on that belief is publish a branch that does not exist.
      final fresh = ProjectStatus.fromJson({
        'project_id': 'P1',
        'branch': 'wip/def456',
      })!;
      expect(distanceSummary(fresh), isNot(contains('matches')));
      expect(distanceSummary(fresh), contains('Nothing of yours'));
    });

    test('both directions are said, because they need opposite actions', () {
      // 3 to publish and 2 to take: naming only one of them hides the half
      // that has to happen first.
      expect(distanceSummary(status), contains('3 of yours'));
      expect(distanceSummary(status), contains('2 from the team'));
    });
  });

  group('why work is not moving', () {
    ProjectStatus withFleet(Map<String, dynamic> providers, {int queued = 1}) =>
        ProjectStatus.fromJson({
          'project_id': 'P1',
          'branch': 'wip/a',
          'main_commit': 'a' * 40,
          'queue': {'queued': queued, 'running': 0},
          'providers': providers,
        })!;

    test('an unserved domain is said even with an empty queue', () {
      // It is a fact about the caller, not the queue: it does not stop being
      // true when a task expires unclaimed, which is exactly the moment the
      // member goes looking for an explanation.
      final notice = fleetNotice(withFleet({'serves_you': false}, queued: 0));
      expect(notice, contains('does not serve your email domain'));
    });

    test(
      'a missing serves_you means served, never a refusal invented here',
      () {
        expect(fleetNotice(withFleet({'online': 2, 'paused': 0})), isNull);
      },
    );

    test(
      'nobody online is its own sentence — the work is not slow, it is unowned',
      () {
        expect(
          fleetNotice(withFleet({'online': 0, 'paused': 0})),
          contains('No computer is online'),
        );
      },
    );

    test('an unreadable fleet says nothing rather than "2 of null"', () {
      expect(fleetNotice(withFleet({'online': 2})), isNull);
    });

    test('a healthy fleet with an empty queue says nothing at all', () {
      // A line reading "0 paused" on every poll is what makes the one that
      // matters invisible.
      expect(
        fleetNotice(withFleet({'online': 2, 'paused': 0}, queued: 0)),
        isNull,
      );
    });
  });

  group('tasks', () {
    test('a state this build has never heard of is watched, not summed up', () {
      // Conservative on purpose: a task in a state this build cannot read may
      // still be running, so it is not terminal — the transcript keeps its
      // live view open rather than printing "It stopped." over a working one.
      final task = CodeTask.fromJson({'id': 't', 'state': 'reticulating'})!;
      expect(task.state, TaskState.unknown);
      expect(task.state.isTerminal, isFalse);
    });

    test('a collected branch is flagged, so its notice can be shown', () {
      // The transcript says a task's files were cleared after the retention
      // window; that line hangs on this flag.
      final task = CodeTask.fromJson({
        'id': 't',
        'state': 'completed',
        'branch': 'task/t',
        'branch_pruned': true,
      })!;
      expect(task.branchPruned, isTrue);
    });

    test('an absent branch_pruned means the branch is still there', () {
      // A relay predating branch collection sends no such key; reading absence
      // the other way would flag every finished task on every older relay as
      // cleared.
      final task = CodeTask.fromJson({
        'id': 't',
        'state': 'completed',
        'branch': 'task/t',
      })!;
      expect(task.branchPruned, isFalse);
    });

    test('queue_expired is told apart from any other failure', () {
      // One word from `deadline_exceeded`, and the opposite action: add
      // computers rather than fix the task.
      final task = CodeTask.fromJson({
        'id': 't',
        'state': 'timed_out',
        'error': 'queue_expired',
      })!;
      expect(task.queueExpired, isTrue);
    });

    test('a pasted multi-line prompt still makes a one-line row', () {
      final task = CodeTask.fromJson({
        'id': 't',
        'state': 'queued',
        'prompt': 'add a retry\n\n  to the upload path\n',
      })!;
      expect(task.summary, 'add a retry to the upload path');
    });

    test('a task with no prompt is still listed, under a name', () {
      expect(CodeTask.fromJson({'id': 't'})!.summary, 'Untitled task');
    });

    test('the transcript shows the request as it was typed, not flattened', () {
      // A rail row had to be one line; a turn in a conversation is the message
      // somebody wrote, and a task prompt runs to paragraphs far more often
      // than a chat message does.
      final task = CodeTask.fromJson({
        'id': 't',
        'state': 'queued',
        'prompt': 'add a retry\n\n  to the upload path\n',
      })!;
      expect(task.asked, 'add a retry\n\n  to the upload path');
      // Nothing to show still falls back to a name rather than a blank bubble.
      expect(CodeTask.fromJson({'id': 't', 'prompt': '  '})!.asked, isNotEmpty);
    });
  });

  group('projects and members', () {
    test('a project with no name is shown by its id rather than dropped', () {
      // It is addressed by id anyway, so it is still perfectly usable.
      expect(GridProject.fromJson({'id': 'P1'})?.name, 'P1');
    });

    test('an entry with no id is dropped — there is nothing to address', () {
      final list = GridProject.listFromJson({
        'projects': [
          {'name': 'nameless'},
          {'id': 'P2', 'name': 'real'},
        ],
      });
      expect(list.map((project) => project.id), ['P2']);
    });

    test('a member’s branch is derived from their key, never from a guess', () {
      final member = ProjectMember.fromJson({
        'member_key': 'def456',
        'role': 'owner',
      })!;
      expect(member.branch, 'wip/def456');
      expect(member.isOwner, isTrue);
    });
  });
}
