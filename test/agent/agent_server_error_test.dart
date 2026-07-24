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

  group('a startup failure reads for a non-technical user', () {
    test('the ACP-dependencies case never shows pip or acp, and offers the '
        'button without promising it works', () {
      final message = friendlyAgentStartupError(
        "Hermes exited during startup: ACP dependencies not installed. Install "
        "them with: pip install -e '.[acp]'",
      );

      // None of Hermes's terminal jargon reaches the chat.
      expect(message.toLowerCase(), isNot(contains('pip')));
      expect(message.toLowerCase(), isNot(contains('acp')));
      expect(message.toLowerCase(), isNot(contains('dependenc')));
      // It names where to try — but this state is usually a fresh install that
      // simply arrived without the piece the chat needs, so Update runs the same
      // command and lands in the same place. Telling the user to reinstall "then
      // try again" is a loop with no end, so the copy must not claim it fixes it.
      expect(message.toLowerCase(), contains('agents'));
      expect(message.toLowerCase(), contains("if that doesn't help"));
    });

    test('a Python import failure is the same missing-setup class', () {
      final message = friendlyAgentStartupError(
        "Hermes exited during startup: ModuleNotFoundError: No module named "
        "'acp'",
      );
      expect(message.toLowerCase(), contains('setup is missing'));
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
}
