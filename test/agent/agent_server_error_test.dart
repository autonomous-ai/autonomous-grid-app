import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_server_error.dart';

/// Hermes hands the grid's failed HTTP call over as if it were the answer, so
/// the chat used to show `HTTP 400: {"detail":…}` in an assistant bubble. These
/// pin the line the user gets instead — and, just as importantly, that a real
/// answer is never mistaken for one of these.
void main() {
  group('a grid refusal becomes a line with a next step', () {
    test('a model that cannot use tools says so, and what to do about it', () {
      final message = friendlyAgentServerError(
        'HTTP 400: {"detail":"No active provider for this model supports '
        'tools"}',
      );

      expect(message, isNotNull);
      expect(message, isNot(contains('HTTP')));
      expect(message, isNot(contains('detail')));
      expect(message!.toLowerCase(), contains('tools'));
      expect(message.toLowerCase(), contains('pick another model'));
    });

    test('nothing serving the model reads as nobody running it, not as a '
        'broken app', () {
      final message = friendlyAgentServerError(
        'HTTP 503: {"detail":"No providers available for this model"}',
      );

      expect(message, contains('Nobody on this grid'));
    });

    test('a rejected token sends the user to sign in again', () {
      final message = friendlyAgentServerError('HTTP 401: {"detail":"nope"}');

      expect(message, contains('Sign out'));
    });

    test(
      'an unrecognised refusal still hides the envelope and names the code',
      () {
        final message = friendlyAgentServerError(
          'HTTP 500: something exploded',
        );

        expect(message, contains('error 500'));
        expect(message, isNot(contains('exploded')));
      },
    );

    test('a body that is not the JSON envelope is handled, not thrown on', () {
      expect(friendlyAgentServerError('HTTP 429: slow down'), isNotNull);
    });
  });

  group('a real answer is left alone', () {
    test('an ordinary reply is not an error', () {
      expect(friendlyAgentServerError('Hello! How can I help?'), isNull);
    });

    test('an answer that merely discusses a status code is still an answer — '
        'only a reply that is nothing but the envelope counts', () {
      expect(
        friendlyAgentServerError(
          'A 400 usually means the request was malformed. HTTP 400: is what '
          'your server would return.',
        ),
        isNull,
      );
    });

    test('an empty reply is not an error envelope — the caller has its own '
        'line for a silent turn', () {
      expect(friendlyAgentServerError('   '), isNull);
    });
  });

  group('an empty model response reads as one, not a Python error', () {
    test(
      'the loop giving up after retries becomes a line with a next step',
      () {
        final message = friendlyAgentEmptyResponse(
          'API call failed after 3 retries: Expecting value: line 1 column 1 '
          '(char 0)',
        );

        expect(message, isNotNull);
        // None of the raw decoder jargon reaches the chat.
        expect(message!.toLowerCase(), isNot(contains('expecting value')));
        expect(message.toLowerCase(), isNot(contains('json')));
        expect(message.toLowerCase(), contains('empty response'));
        expect(message.toLowerCase(), contains('pick another model'));
      },
    );

    test('a bare JSON-decode error is the same empty-response failure', () {
      expect(
        friendlyAgentEmptyResponse('Expecting value: line 1 column 1 (char 0)'),
        isNotNull,
      );
    });

    test('an answer that merely mentions the decode error is left alone — only '
        'a reply that starts as the failure counts', () {
      expect(
        friendlyAgentEmptyResponse(
          "The error 'Expecting value: line 1 column 1 (char 0)' means the JSON "
          'body was empty. Here is how to handle it in your parser: …',
        ),
        isNull,
      );
    });

    test('an ordinary reply and an empty one are both left for the caller', () {
      expect(friendlyAgentEmptyResponse('Hello! How can I help?'), isNull);
      expect(friendlyAgentEmptyResponse('   '), isNull);
    });
  });

  group('a startup failure reads for a non-technical user', () {
    test('the ACP-dependencies case never shows pip or acp, and reports the '
        'repair the app already attempted', () {
      final message = friendlyAgentStartupError(
        "Hermes exited during startup: ACP dependencies not installed. Install "
        "them with: pip install -e '.[acp]'",
      );

      // None of Hermes's terminal jargon reaches the chat.
      expect(message.toLowerCase(), isNot(contains('pip')));
      expect(message.toLowerCase(), isNot(contains('acp')));
      expect(message.toLowerCase(), isNot(contains('dependenc')));
      // The app finishes the install itself, so by the time this line is shown
      // that has been tried and failed: it says so, names the thing the user can
      // actually change (their connection), and points at Update — without
      // claiming Update will work.
      expect(message, contains(kAgentSetupUnfinished));
      expect(message.toLowerCase(), contains('connection'));
      expect(message.toLowerCase(), contains('agents'));
    });

    test('a Python import failure is the same missing-setup class', () {
      final message = friendlyAgentStartupError(
        "Hermes exited during startup: ModuleNotFoundError: No module named "
        "'acp'",
      );
      expect(message, contains(kAgentSetupUnfinished));
      expect(message, isNot(contains('ModuleNotFoundError')));
    });

    test('an unrecognised reason stays calm — no traceback in the chat', () {
      final message = friendlyAgentStartupError(
        'Hermes exited during startup: Traceback (most recent call last): '
        'RuntimeError: something obscure',
      );
      expect(message.toLowerCase(), contains("wouldn't start"));
      expect(message.toLowerCase(), contains('agents'));
      expect(message, isNot(contains('Traceback')));
      expect(message, isNot(contains('RuntimeError')));
    });
  });

  group("a build that can't read the connection Grid wrote", () {
    const raw =
        "hermes_cli.auth.AuthError: Unknown provider 'grid'. Check 'hermes "
        "model' for available providers, or run 'hermes doctor' to diagnose "
        'config issues.';

    test('the model the assistant was pointed at is named as the thing to '
        'change — the assistant itself installed and ran fine', () {
      final message = friendlyAgentUnknownProvider(raw);
      expect(message, kAgentProviderUnknown);
      expect(message!.toLowerCase(), contains('model'));
      expect(message.toLowerCase(), contains('update'));
      // Hermes's own instructions name commands the user has no terminal for.
      expect(message, isNot(contains('hermes doctor')));
      expect(message, isNot(contains('AuthError')));
    });

    test('it beats the install cases at the startup path, which would send the '
        'user to finish an install that is already finished', () {
      expect(
        friendlyAgentStartupError('Hermes exited during startup: $raw'),
        kAgentProviderUnknown,
      );
    });

    test("another provider's complaint keeps the assistant's own words — this "
        "line is about the connection *Grid* writes", () {
      expect(
        friendlyAgentUnknownProvider("Unknown provider 'openrouter'."),
        isNull,
      );
      expect(friendlyAgentUnknownProvider('a perfectly good answer'), isNull);
    });
  });
}
