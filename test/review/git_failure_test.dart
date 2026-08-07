import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/git_failure.dart';

/// The raw strings are what Git 2.33 actually prints. A humanised line built
/// from a paraphrase would stop matching the moment it met the real thing.
void main() {
  test('a push that could not sign in says so, and says where the way out is '
      '— the app is what disabled the password prompt', () {
    final line = friendlyGitFailure(
      "fatal: could not read Username for 'https://github.com': terminal "
      'prompts disabled',
      remote: 'origin',
    );

    expect(line, contains('sign in'));
    expect(line, contains('origin'));
    expect(line, contains('Terminal'));
  });

  test('an SSH key the remote does not accept is the same problem in a '
      'different coat, and reads as one', () {
    expect(
      friendlyGitFailure('git@github.com: Permission denied (publickey).'),
      contains('sign in'),
    );
  });

  test('a commit with no identity set gives the two commands that fix it, '
      'because "tell me who you are" is not something the app can do', () {
    final line = friendlyGitFailure(
      '*** Please tell me who you are.\n\nRun\n\n  git config --global '
      'user.email "you@example.com"',
    );

    expect(line, contains('user.name'));
    expect(line, contains('user.email'));
  });

  test('a rejected push names what happened rather than "non-fast-forward"', () {
    final line = friendlyGitFailure(
      ' ! [rejected]        main -> main (non-fast-forward)',
      branch: 'main',
    );

    expect(line, contains('pushed to “main”'));
    expect(line, contains('Pull'));
  });

  test('an unreachable remote is told apart from a refused one: one is the '
      "network, the other is permission", () {
    expect(
      friendlyGitFailure(
        "ssh: Could not resolve hostname github.com: nodename nor servname "
        'provided',
      ),
      contains('internet connection'),
    );
  });

  test('a failure nothing matches shows Git\'s own first line rather than a '
      'guess the user cannot check', () {
    expect(
      friendlyGitFailure('fatal: bad object HEAD~9999\nsecond line'),
      'Bad object HEAD~9999',
    );
  });

  test('a failure with nothing in it still says something', () {
    expect(friendlyGitFailure('   \n\n'), isNotEmpty);
  });

  test('a wall of output is cut rather than filling the screen', () {
    final line = friendlyGitFailure('fatal: ${'x' * 500}');

    expect(line.length, lessThanOrEqualTo(201));
    expect(line, endsWith('…'));
  });
}
