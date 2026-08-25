import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/codex_app_server_service.dart';
import 'package:grid_app/infrastructure/cli/host_environment.dart';

void main() {
  // One test over all three agents, deliberately. Three tests each reading one
  // is the shape that lets a single builder stop merging the shared
  // environment while the other two keep the suite green — and a variable that
  // never arrives is not an error anywhere, so nothing else would report it.
  test('every agent Grid spawns inherits the shared Grid environment', () {
    final shared = HostEnvironment.agentEnvironment();
    // The positive control. Without it the loops below pass by having nothing
    // to check, so a contributor that quietly came back empty would read as
    // three healthy agents.
    expect(shared, isNotEmpty);
    expect(shared, contains('PATH'));

    final spawned = {
      'Claude Code': claudeExecEnvironment(),
      'Codex': codexAppServerEnvironment(),
      'Hermes': HostEnvironment.hermesEnvironment(),
    };

    for (final MapEntry(key: agent, value: environment) in spawned.entries) {
      for (final MapEntry(key: name, value: value) in shared.entries) {
        expect(
          environment[name],
          value,
          reason: '$agent is spawned without $name',
        );
      }
    }
  });

  // What the test above cannot see. Hermes reads its environment at the
  // `Process.start` that uses it, but Claude Code and Codex build theirs one
  // hop away, and a call site that went back to passing the turn's own map
  // straight through would spawn an un-augmented child with every assertion
  // above still green. There is no seam to reach that hop through, so this
  // reads the source instead — a structural guard, and honest about being one.
  test('the Claude and Codex spawns still go through their builder', () {
    const sites = {
      'lib/infrastructure/cli/claude_exec_service.dart':
          'environment: claudeExecEnvironment(',
      'lib/infrastructure/cli/codex_app_server_service.dart':
          'environment: codexAppServerEnvironment(',
    };

    for (final MapEntry(key: path, value: call) in sites.entries) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: '$path moved — this guard is reading nothing',
      );
      final source = file.readAsStringSync();
      // The floor: a file that no longer spawns anything would satisfy the
      // real check below by having nothing to fail.
      expect(
        source,
        contains('Process.start('),
        reason: '$path spawns nothing',
      );
      expect(source, contains(call), reason: '$path spawns without $call');
    }
  });

  // The one branch in [claudeExecEnvironment] that is not a plain merge, and
  // the one that matters most: on the extension lane the relay's credentials
  // must not reach the turn at all, and the app's own process can be carrying
  // one a developer exported. The removal therefore has to run last, over the
  // merged map — a version that only looked at the turn's own keys, or that
  // ran before the merge, would leak exactly that case and stay green.
  test('a name the turn must not carry is gone however it arrived', () {
    // `PATH` stands in for such a credential: it comes from the shared
    // contributor, never from the turn's map.
    final fromThisProcess = claudeExecEnvironment(
      environment: const {'GRID_TEST_KEPT': 'kept'},
      dropEnvironment: const {'PATH'},
    );
    expect(
      fromThisProcess.containsKey('PATH'),
      isFalse,
      reason: 'a dropped name this process contributed survived',
    );
    expect(fromThisProcess['GRID_TEST_KEPT'], 'kept');

    final fromTheTurn = claudeExecEnvironment(
      environment: const {'GRID_TEST_DROPPED': 'leaked'},
      dropEnvironment: const {'GRID_TEST_DROPPED'},
    );
    expect(
      fromTheTurn.containsKey('GRID_TEST_DROPPED'),
      isFalse,
      reason: "a dropped name the turn's own map carried survived",
    );
  });
}
