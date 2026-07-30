import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';
import 'package:grid_app/features/network/logic/client_app_grid_support.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

GridOverview _overview({bool? chat, bool? responses, bool? messages}) =>
    GridOverview(
      stats: const GridStats(models: 1, nodes: 1),
      models: const [],
      nodes: const [],
      advertisesChatCompletions: chat,
      advertisesResponses: responses,
      advertisesMessages: messages,
    );

void main() {
  test('each client is matched to the one dialect it speaks, so a grid that '
      'answers two of the three is not read as answering all of them', () {
    expect(clientDialect(ClientApp.claudeCode), RelayDialect.messages);
    expect(clientDialect(ClientApp.codex), RelayDialect.responses);
    // Hermes switches to Responses only when its model needs it, so a
    // chat-completions grid is enough for it.
    expect(clientDialect(ClientApp.hermes), RelayDialect.chatCompletions);
  });

  test('Claude Code is ruled out only by the Messages flag — a grid can answer '
      'chat and Responses and still have nothing to say to it', () {
    final grid = _overview(chat: true, responses: true, messages: false);

    expect(clientRunsOnGrid(ClientApp.claudeCode, grid), isFalse);
    expect(clientRunsOnGrid(ClientApp.codex, grid), isTrue);
    expect(clientRunsOnGrid(ClientApp.hermes, grid), isTrue);
  });

  test('the live shape of a grid serving Messages but not Responses: Claude '
      'Code runs, Codex does not', () {
    final grid = _overview(chat: true, responses: false, messages: true);

    expect(clientRunsOnGrid(ClientApp.claudeCode, grid), isTrue);
    expect(clientRunsOnGrid(ClientApp.codex, grid), isFalse);
  });

  test('a relay that never reported the flag lets the app try — reading the '
      'silence as "no" would strand every user of an older grid', () {
    for (final grid in [null, _overview()]) {
      for (final app in kSelectableClientApps) {
        expect(
          clientRunsOnGrid(app, grid),
          isTrue,
          reason: '${app.name} on an overview that says nothing',
        );
      }
    }
  });

  test('the reason names the app in the same words the Agents list uses', () {
    expect(
      appUnsupportedHere('Claude Code'),
      "This grid doesn't serve a model Claude Code can talk to.",
    );
  });
}
