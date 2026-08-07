import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_comment.dart';
import 'package:grid_app/features/review/logic/review_comments_controller.dart';

ReviewComment comment(int line, String text, {String path = 'lib/a.dart'}) =>
    ReviewComment(path: path, side: DiffSide.after, line: line, text: text);

ProviderContainer container() {
  final made = ProviderContainer();
  addTearDown(made.dispose);
  return made;
}

void main() {
  test('a second remark on the same line rewrites the first — there is nobody '
      'to reply to, and two would reach the assistant as one instruction '
      'anyway', () {
    final held = container();
    final notifier = held.read(reviewCommentsProvider('/repo').notifier);

    notifier.add(comment(32, 'Rename this'));
    notifier.add(comment(32, 'Actually, delete it'));

    final comments = held.read(reviewCommentsProvider('/repo'));
    expect(comments.length, 1);
    expect(comments.single.text, 'Actually, delete it');
  });

  test('remarks on different lines stand alongside each other, in the order '
      'they were written', () {
    final held = container();
    final notifier = held.read(reviewCommentsProvider('/repo').notifier);

    notifier.add(comment(32, 'First'));
    notifier.add(comment(40, 'Second'));

    expect(held.read(reviewCommentsProvider('/repo')).map((c) => c.text), [
      'First',
      'Second',
    ]);
  });

  test('taking one back leaves the rest, so a change of mind is not a reason '
      'to write everything again', () {
    final held = container();
    final notifier = held.read(reviewCommentsProvider('/repo').notifier);
    notifier.add(comment(32, 'First'));
    notifier.add(comment(40, 'Second'));

    notifier.remove(comment(32, 'First'));

    expect(held.read(reviewCommentsProvider('/repo')).single.text, 'Second');
  });

  test('sending clears them: a request that has been handed over must not ride '
      'along with the next question too', () {
    final held = container();
    final notifier = held.read(reviewCommentsProvider('/repo').notifier);
    notifier.add(comment(32, 'First'));

    notifier.clear();

    expect(held.read(reviewCommentsProvider('/repo')), isEmpty);
  });

  test("one project's comments do not follow the user into another — they "
      'point at lines in files that repository has', () {
    final held = container();

    held.read(reviewCommentsProvider('/repo').notifier).add(comment(1, 'Here'));

    expect(held.read(reviewCommentsProvider('/other')), isEmpty);
  });

  test('only one comment box is open at a time, and closing it leaves nothing '
      'behind for the next line to inherit', () {
    final held = container();
    final drafts = held.read(reviewCommentDraftProvider('/repo').notifier);

    drafts.open(
      const CommentDraft(
        path: 'lib/a.dart',
        side: DiffSide.after,
        line: 32,
        code: 'final x = 1;',
      ),
    );
    expect(held.read(reviewCommentDraftProvider('/repo'))?.line, 32);

    drafts.close();
    expect(held.read(reviewCommentDraftProvider('/repo')), isNull);
  });

  test('the box carries the line it was opened on into the comment it makes, '
      'so the quote in the prompt is what was on screen', () {
    const draft = CommentDraft(
      path: 'lib/a.dart',
      side: DiffSide.after,
      line: 32,
      code: 'final x = 1;',
    );

    final made = draft.toComment('Rename this');

    expect(made.path, 'lib/a.dart');
    expect(made.line, 32);
    expect(made.code, 'final x = 1;');
    expect(made.text, 'Rename this');
  });
}
