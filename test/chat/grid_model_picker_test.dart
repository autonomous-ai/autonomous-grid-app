import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/presentation/grid_model_picker.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/shared/widgets/skeleton.dart';

NetworkCredential _network(String id, String name) => NetworkCredential(
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

/// Opens the picker's menu with [grids] in the session, each grid's `/models`
/// answering from [models] (id → the list it serves).
Future<void> _openMenu(
  WidgetTester tester, {
  required List<NetworkCredential> grids,
  required Map<String, List<String>> models,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(
            networks: grids,
            activeNetwork: grids.first.networkId,
          ),
        ),
        for (final grid in grids)
          networkModelsForProvider(
            grid.networkId,
          ).overrideWith((ref) async => models[grid.networkId] ?? const []),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: GridModelPicker(currentModelId: '', onSelect: (_, _) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(GridModelPicker));
  await tester.pumpAndSettle();
}

void main() {
  final empty = _network('grid-empty', 'Empty Grid');
  final serving = _network('grid-serving', 'Serving Grid');

  testWidgets('the list is skeletoned until the grid has answered', (
    tester,
  ) async {
    final slow = Completer<List<String>>();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(
            CredentialsFile(networks: [serving], activeNetwork: 'grid-serving'),
          ),
          networkModelsForProvider(
            'grid-serving',
          ).overrideWith((ref) => slow.future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: GridModelPicker(currentModelId: '', onSelect: (_, _) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(GridModelPicker));
    // Let the menu open without draining the pending /models future.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Mid-flight: the shape is there, the models are not.
    expect(find.byType(Skeleton), findsWidgets);
    expect(find.text('maker/m1'), findsNothing);

    slow.complete(const ['maker/m1']);
    await tester.pumpAndSettle();

    // Settled: skeleton gone, the real rows in its place.
    expect(find.byType(Skeleton), findsNothing);
    expect(find.text('maker/m1'), findsOneWidget);
  });

  testWidgets('a grid serving nothing says so', (tester) async {
    await _openMenu(tester, grids: [empty], models: {'grid-empty': const []});

    expect(
      find.text("This grid isn't serving a model right now."),
      findsOneWidget,
    );
  });

  testWidgets('each kind of row carries its own mark', (tester) async {
    await _openMenu(
      tester,
      grids: [serving],
      models: {
        'grid-serving': const ['maker/m1'],
      },
    );

    // A chat model and the two media modes are three different jobs; each gets
    // a glyph of its own rather than the media ones being marked and chat left
    // blank.
    expect(
      modalityIcon(PlaygroundModality.text),
      Icons.chat_bubble_outline_rounded,
    );
    expect(modalityIcon(PlaygroundModality.image), Icons.auto_awesome_outlined);
    expect(modalityIcon(PlaygroundModality.video), Icons.slideshow_outlined);
    expect(
      {
        modalityIcon(PlaygroundModality.text),
        modalityIcon(PlaygroundModality.image),
        modalityIcon(PlaygroundModality.video),
      },
      hasLength(3),
      reason: 'a shared glyph would tell two kinds of row apart not at all',
    );

    // The chat model's row is marked, where it used to render an empty slot.
    expect(
      find.descendant(
        of: find
            .ancestor(of: find.text('maker/m1'), matching: find.byType(Row))
            .first,
        matching: find.byIcon(Icons.chat_bubble_outline_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the pill wears the mark of what is selected', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpWith(String id) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(
              CredentialsFile(
                networks: [serving],
                activeNetwork: 'grid-serving',
              ),
            ),
            networkModelsForProvider(
              'grid-serving',
            ).overrideWith((ref) async => const ['maker/m1']),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: GridModelPicker(currentModelId: id, onSelect: (_, _) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpWith('maker/m1');
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);

    // The media modes carry fixed labels, not maker/name ids — the pill reads
    // the mode straight off the id.
    await pumpWith(kVideoModeLabel);
    expect(find.byIcon(Icons.slideshow_outlined), findsOneWidget);

    // Nothing picked yet: the pill is prompting, so it wears no mode's mark.
    await pumpWith('');
    expect(find.text('Choose model'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.slideshow_outlined), findsNothing);
  });

  testWidgets('the pill says which grid is answering, not just which model', (
    tester,
  ) async {
    // The case from the screenshot: two grids serving identically-named models,
    // so the model name alone can't say whose machine is on the other end.
    final art = _network('grid-art', 'Art');
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(
            CredentialsFile(
              networks: [serving, art],
              activeNetwork: 'grid-art',
            ),
          ),
          for (final id in ['grid-serving', 'grid-art'])
            networkModelsForProvider(
              id,
            ).overrideWith((ref) async => const ['maker/shared']),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: 140,
                child: GridModelPicker(
                  currentModelId: 'maker/shared',
                  onSelect: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'shared\non Art',
    );
  });

  testWidgets('with nothing picked the pill prompts instead of reporting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(
            CredentialsFile(networks: [serving], activeNetwork: 'grid-serving'),
          ),
          networkModelsForProvider(
            'grid-serving',
          ).overrideWith((ref) async => const ['maker/m1']),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: GridModelPicker(currentModelId: '', onSelect: (_, _) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Choose which model answers',
    );
  });
}
