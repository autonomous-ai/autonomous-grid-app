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

    test('an unremembered pick opens the door without writing anything', () {
      final container = containerWith([lab, office]);

      container
          .read(gridChoiceGateProvider.notifier)
          .choose(office, remember: false);

      expect(
        container.read(gridChoiceNeededProvider),
        isFalse,
        reason: 'the user answered — this run goes in on the grid they picked',
      );
      expect(
        container.read(selectedNetworkProvider)?.networkId,
        'net-2',
        reason: 'not remembering it must not mean not using it',
      );
      expect(
        ChatPrefsStore(
          file: File('${temp.path}/chat_prefs.json'),
        ).load().networkId,
        isNull,
        reason: 'nothing on disk, so the next launch asks again',
      );
    });

    test('signing out shuts the door, so the next account is asked again', () {
      final container = containerWith([lab, office]);
      container.read(gridChoiceGateProvider.notifier).choose(office);
      expect(container.read(gridChoiceGateProvider), isTrue);

      // What signing out looks like from here: `grid logout` empties the
      // credentials file, which is the only thing the session reads.
      store.credentials = CredentialsFile.empty;
      container.invalidate(sessionProvider);

      expect(
        container.read(gridChoiceGateProvider),
        isFalse,
        reason:
            'a door held open across a sign-out sends the account signing in '
            'next straight past the question onto a grid it never picked',
      );
    });

    test('the whole question comes back for whoever signs in next', () {
      final container = containerWith([lab, office]);
      // Subscribed for the whole run, because `RootView` is: without a listener
      // the container is lazy, the signed-out moment is never computed, and the
      // gate compares the second sign-in against the first and sees no change.
      // The bug this covers only exists in a tree that is watching.
      container.listen(gridChoiceNeededProvider, (_, _) {});
      container.read(gridChoiceGateProvider.notifier).choose(office);
      expect(container.read(gridChoiceNeededProvider), isFalse);

      // Sign out. The remembered grid goes with the logout, exactly as it does
      // on disk — `grid logout` clears the pointer along with the credentials.
      store.credentials = CredentialsFile.empty;
      File('${temp.path}/chat_prefs.json').deleteSync();
      container.invalidate(chatPrefsProvider);
      container.invalidate(sessionProvider);
      expect(container.read(gridChoiceNeededProvider), isTrue);

      // Sign back in, on an account that holds grids of its own.
      store.credentials = _credentials([lab, office]);
      container.invalidate(sessionProvider);

      expect(
        container.read(gridChoiceNeededProvider),
        isTrue,
        reason: 'the second sign-in is a first run for that account',
      );
    });

    test('forgetting the grid on sign-out un-answers the question', () {
      final container = containerWith([lab, office]);
      container.listen(gridChoiceNeededProvider, (_, _) {});
      container.read(gridChoiceGateProvider.notifier).choose(office);
      expect(container.read(gridChoiceNeededProvider), isFalse);

      // Signing out: the credentials go, and the app forgets the grid that
      // account picked. `grid logout` clears the CLI's pointer but never
      // touches `chat_prefs.json`, so the app has to clear its own.
      store.credentials = CredentialsFile.empty;
      container.read(chatPrefsProvider.notifier).clearNetwork();
      container.invalidate(sessionProvider);
      expect(container.read(gridChoiceNeededProvider), isTrue);

      // Someone signs in on the same machine, holding a grid by the same id.
      store.credentials = _credentials([lab, office]);
      container.invalidate(sessionProvider);

      expect(
        container.read(gridChoiceNeededProvider),
        isTrue,
        reason:
            'inheriting the previous account’s grid because the ids happen to '
            'match is worse than asking — it puts one person’s chats on '
            'another person’s grid without either of them being told',
      );
    });

    test('forgetting the grid keeps every other preference', () {
      final container = containerWith([lab, office]);
      container.read(chatPrefsProvider.notifier).setChatAgent('codex');
      container.read(gridChoiceGateProvider.notifier).choose(office);

      container.read(chatPrefsProvider.notifier).clearNetwork();

      final prefs = ChatPrefsStore(
        file: File('${temp.path}/chat_prefs.json'),
      ).load();
      expect(prefs.networkId, isNull);
      expect(
        prefs.chatAgent,
        'codex',
        reason:
            'the grid belongs to the account, the rest belongs to the person '
            'at the keyboard — signing out must not reset their app',
      );
    });
  });
}
