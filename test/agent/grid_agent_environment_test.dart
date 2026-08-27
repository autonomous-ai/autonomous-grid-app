import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/codex_app_server_service.dart';
import 'package:grid_app/infrastructure/cli/host_environment.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

void main() {
  group('the grid the app is on is the grid an agent searches through',
      _selectionAdoptsTheGrid);

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

  // Seam 3b (public-repo ADR 0036 D-e). The hazard the ADR calls out as having
  // no existing net: the pair must be in all THREE spawn environments, and a
  // pair added to two of them takes web search away from the third in silence,
  // because a missing environment variable is not an error anywhere. One test
  // reading all three, for the same reason the one above is.
  test('every agent Grid spawns is told which grid it is on', () {
    const url = 'https://relay.invalid/relay/v1';
    const token = 'per-grid-access-token';
    HostEnvironment.adoptGrid(relayBaseUrl: url, relayToken: token);
    addTearDown(HostEnvironment.adoptGrid);

    final spawned = {
      'Claude Code': claudeExecEnvironment(),
      'Codex': codexAppServerEnvironment(),
      'Hermes': HostEnvironment.hermesEnvironment(),
    };

    for (final MapEntry(key: agent, value: environment) in spawned.entries) {
      expect(
        environment[HostEnvironment.relayUrlVar],
        url,
        reason: '$agent cannot reach the grid to search the web',
      );
      expect(
        environment[HostEnvironment.relayTokenVar],
        token,
        reason: '$agent has no credential for the grid',
      );
    }
  });

  // The other direction, and the one nothing else would catch. `adoptGrid`
  // with no grid is what signing out looks like, and the inherited environment
  // is where a developer's own `GRID_RELAY_TOKEN` — a live credential for
  // somebody else's grid — would be sitting.
  test('no grid picked means no credential, however it got there', () {
    HostEnvironment.adoptGrid();

    final environment = HostEnvironment.agentEnvironment(
      environment: const {
        'GRID_RELAY_URL': 'https://someone-elses-grid.invalid/relay/v1',
        'GRID_RELAY_TOKEN': 'a-token-for-a-grid-this-app-is-not-on',
        'GRID_TEST_KEPT': 'kept',
      },
    );

    expect(environment.containsKey(HostEnvironment.relayUrlVar), isFalse);
    expect(environment.containsKey(HostEnvironment.relayTokenVar), isFalse);
    // The positive control: a builder that returned an empty map would satisfy
    // both assertions above without doing anything.
    expect(environment['GRID_TEST_KEPT'], 'kept');
  });

  test('half a pair is never handed down', () {
    // A URL with no token is a script posting unauthenticated and being refused
    // at the far end, which reads as a broken grid rather than as one not
    // picked yet — and it is the state a partially-populated credential
    // produces, so it is not hypothetical.
    HostEnvironment.adoptGrid(relayBaseUrl: 'https://relay.invalid/relay/v1');
    addTearDown(HostEnvironment.adoptGrid);

    final environment = HostEnvironment.agentEnvironment(
      environment: const {'GRID_TEST_KEPT': 'kept'},
    );

    expect(environment.containsKey(HostEnvironment.relayUrlVar), isFalse);
    expect(environment.containsKey(HostEnvironment.relayTokenVar), isFalse);
    expect(environment['GRID_TEST_KEPT'], 'kept');
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

/// The other half of the contract: [HostEnvironment.adoptGrid] holds whatever
/// it was last told, so the question that decides whether an agent can search
/// the web is *who tells it*, and when.
///
/// [SelectedNetwork] has two write paths — [SelectedNetwork.build], which
/// re-runs on every refresh of the credential list, and [SelectedNetwork.select],
/// which does not re-run it. Two doors onto one fact is the shape where a
/// second caller inherits none of the first one's guards, so both are driven
/// here rather than one.
void _selectionAdoptsTheGrid() {
  NetworkCredential grid(String id) => NetworkCredential(
    networkId: id,
    name: id,
    networkType: 'permissioned',
    lanSignalingUrl: 'https://$id.invalid',
    accessToken: 'token-for-$id',
    refreshToken: '',
    email: 'dev@example.com',
    nodeId: 'node',
    deviceId: 'device',
    roles: const ['consumer'],
    scopes: const ['consumer:chat'],
    memberEpoch: 1,
    networkEpoch: 1,
    expiresAt: 0,
  );

  ProviderContainer containerFor(List<NetworkCredential> networks) {
    final prefsFile = File(
      '${Directory.systemTemp.createTempSync('grid-prefs').path}/prefs.json',
    );
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(networks: networks, sessionToken: 'session'),
        ),
        activeRemoteGridProvider.overrideWithValue(null),
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: prefsFile),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() => prefsFile.parent.deleteSync(recursive: true));
    return container;
  }

  setUp(HostEnvironment.adoptGrid);
  tearDown(HostEnvironment.adoptGrid);

  test('resolving a grid hands its relay and token to the next agent', () {
    final container = containerFor([grid('grid-a')]);

    container.read(selectedNetworkProvider);

    final environment = HostEnvironment.agentEnvironment(
      environment: const {},
    );
    expect(
      environment[HostEnvironment.relayUrlVar],
      'https://grid-a.invalid/relay/v1',
    );
    expect(environment[HostEnvironment.relayTokenVar], 'token-for-grid-a');
  });

  test('switching grids replaces the credential, it does not add one', () {
    // `select` sets `state` directly and never re-runs `build`, so an
    // implementation that adopted only in `build` would leave every agent
    // searching on the grid the person just left — silently, and with the
    // previous grid's name on the spend.
    final container = containerFor([grid('grid-a'), grid('grid-b')]);
    container.read(selectedNetworkProvider);

    container
        .read(selectedNetworkProvider.notifier)
        .select(container.read(sessionProvider).networks.last);

    final environment = HostEnvironment.agentEnvironment(
      environment: const {},
    );
    expect(
      environment[HostEnvironment.relayUrlVar],
      'https://grid-b.invalid/relay/v1',
    );
    expect(environment[HostEnvironment.relayTokenVar], 'token-for-grid-b');
  });

  test('no grid to resolve takes the credential away', () {
    // Signing out, or leaving the last grid. Null is a value here: leaving the
    // previous token live would keep an agent posting to a grid the app is no
    // longer on.
    HostEnvironment.adoptGrid(
      relayBaseUrl: 'https://stale.invalid/relay/v1',
      relayToken: 'stale',
    );
    final container = containerFor(const []);

    expect(container.read(selectedNetworkProvider), isNull);

    final environment = HostEnvironment.agentEnvironment(
      environment: const {},
    );
    expect(environment.containsKey(HostEnvironment.relayUrlVar), isFalse);
    expect(environment.containsKey(HostEnvironment.relayTokenVar), isFalse);
  });
}
