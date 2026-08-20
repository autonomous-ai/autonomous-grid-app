import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/grid_choice.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// Which grid the user is on decides what every screen behind the choice screen
/// reads — what model is available, where chat sends, what this computer would
/// share. Getting the "have they answered yet?" rule wrong either asks a
/// returning user again on every launch, or lets a first-time user straight past
/// the question onto a grid that was picked for them.

NetworkCredential _grid({required String id, required String name}) =>
    NetworkCredential(
      networkId: id,
      name: name,
      networkType: 'permissioned',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: '',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: const ['consumer'],
      scopes: const ['consumer:chat'],
      memberEpoch: 1,
      networkEpoch: 1,
      expiresAt: 0,
    );

CredentialsFile _credentials(List<NetworkCredential> networks) =>
    CredentialsFile(networks: networks, sessionToken: 'session');

/// `~/.grid` never appears in a test (§8), so the credentials the app reads and
/// the prefs it writes both come from here. Mutable, so a test can take a grid
/// away the way a deletion does and re-read.
class _FakeStore extends GridHomeStore {
  _FakeStore(this.credentials);

  CredentialsFile credentials;

  @override
  CredentialsFile readCredentials() => credentials;

  @override
  String? readActiveRemoteGrid() => null;
}

void main() {
  final lab = _grid(id: 'net-1', name: 'Lab');
  final office = _grid(id: 'net-2', name: 'Office');

  test('asks the first time, before the user has picked anything', () {
    expect(
      needsGridChoice(
        credentials: _credentials([lab, office]),
        chosenGridId: null,
      ),
      isTrue,
    );
  });

  test(
    'asks again when the grid the user picked is no longer on the account',
    () {
      expect(
        needsGridChoice(
          credentials: _credentials([office]),
          chosenGridId: 'net-1',
        ),
        isTrue,
        reason: 'they left the grid or it was deleted — do not chat into it',
      );
    },
  );

  test('stays out of the way once a grid they still hold was picked', () {
    expect(
      needsGridChoice(
        credentials: _credentials([lab, office]),
        chosenGridId: 'net-1',
      ),
      isFalse,
    );
  });

  test('accepts a remembered grid stored by name, as the CLI writes it', () {
    expect(
      needsGridChoice(credentials: _credentials([lab]), chosenGridId: 'Lab'),
      isFalse,
    );
  });

  test('asks when the account has no grids at all, so one can be created', () {
    expect(
      needsGridChoice(credentials: _credentials([]), chosenGridId: null),
      isTrue,
    );
  });

  test('treats a blank remembered id as never having been asked', () {
    expect(
      needsGridChoice(credentials: _credentials([lab]), chosenGridId: '   '),
      isTrue,
    );
  });

  group('wired to the app', () {
    late Directory temp;

    late _FakeStore store;

    ProviderContainer containerWith(List<NetworkCredential> networks) {
      store = _FakeStore(_credentials(networks));
      final container = ProviderContainer(
        overrides: [
          gridHomeStoreProvider.overrideWithValue(store),
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${temp.path}/chat_prefs.json')),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(() => temp = Directory.systemTemp.createTempSync('grid_choice'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('picking a grid is what answers the question, and it sticks', () {
      final container = containerWith([lab, office]);
      expect(container.read(gridChoiceNeededProvider), isTrue);

      container.read(gridChoiceGateProvider.notifier).choose(office);

      expect(
        container.read(gridChoiceNeededProvider),
        isFalse,
        reason: 'the screen has to fall away the moment a grid is picked',
      );
      expect(
        ChatPrefsStore(
          file: File('${temp.path}/chat_prefs.json'),
        ).load().networkId,
        'net-2',
        reason: 'remembered on disk, so the next launch opens on chat',
      );
    });

    test('the screen does not come back when the grid is deleted later', () {
      final container = containerWith([lab, office]);
      container.read(gridChoiceGateProvider.notifier).choose(office);
      expect(container.read(gridChoiceNeededProvider), isFalse);

      // What deleting the open grid looks like from here.
      store.credentials = _credentials([lab]);
      container.invalidate(sessionProvider);

      expect(
        container.read(gridChoiceNeededProvider),
        isFalse,
        reason:
            'the whole window must not turn into the first-run screen while '
            'the user is standing in Settings',
      );
      expect(
        needsGridChoice(
          credentials: _credentials([lab]),
          chosenGridId: 'net-2',
        ),
        isTrue,
        reason:
            'the rule itself still reads it as unanswered — the door is the '
            'only thing keeping the user in, so it has to be a door',
      );
    });

    test('choosing later lets the user in without an answer on record', () {
      final container = containerWith([]);
      expect(container.read(gridChoiceNeededProvider), isTrue);

      container.read(gridChoiceGateProvider.notifier).later();

      expect(container.read(gridChoiceNeededProvider), isFalse);
      expect(
        ChatPrefsStore(
          file: File('${temp.path}/chat_prefs.json'),
        ).load().networkId,
        isNull,
        reason: 'a skip is not an answer — the next launch asks again',
      );
    });
  });
}
