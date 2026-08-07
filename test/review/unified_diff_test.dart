import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/unified_diff.dart';

/// The fixtures are real `git diff` output (Git 2.33), hashes shortened.
void main() {
  group('parseUnifiedDiff', () {
    test('numbers each side of the change the way the gutter draws it: a '
        'removed line has no line number on the new side, and vice versa', () {
      final patch = parseUnifiedDiff('''
diff --git a/mod.txt b/mod.txt
index 422c2b7..7be73ce 100644
--- a/mod.txt
+++ b/mod.txt
@@ -1,2 +1,3 @@
 a
-b
+B
+c
''');

      final rows = patch.hunks.single.rows;
      expect(rows.map((r) => r.kind), [
        DiffRowKind.context,
        DiffRowKind.removed,
        DiffRowKind.added,
        DiffRowKind.added,
      ]);
      expect(rows[0].oldLine, 1);
      expect(rows[0].newLine, 1);
      expect(rows[1].oldLine, 2);
      expect(rows[1].newLine, isNull);
      expect(rows[2].oldLine, isNull);
      expect(rows[2].newLine, 2);
      expect(rows[3].newLine, 3);
    });

    test('keeps every hunk of a file, with the heading Git puts on it — that '
        'heading is the only clue to where in the file you are', () {
      final patch = parseUnifiedDiff('''
diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,3 @@ class Foo {
 one
-two
+TWO
@@ -40,2 +40,3 @@ void bar() {
 forty
+forty-one
''');

      expect(patch.hunks.length, 2);
      expect(patch.hunks.first.context, 'class Foo {');
      expect(patch.hunks.last.rows.last.newLine, 41);
    });

    test("carries Git's no-newline aside without counting it as a line of the "
        'file — it belongs to neither side', () {
      final patch = parseUnifiedDiff('''
diff --git a/nonl.txt b/nonl.txt
--- a/nonl.txt
+++ b/nonl.txt
@@ -1,2 +1,2 @@
 x
-y
\\ No newline at end of file
+z
\\ No newline at end of file
''');

      final notes = patch.hunks.single.rows.where(
        (r) => r.kind == DiffRowKind.note,
      );
      expect(notes.length, 2);
      expect(notes.first.text, 'No newline at end of file');
      expect(notes.first.oldLine, isNull);
      expect(notes.first.newLine, isNull);
    });

    test('says a file is binary instead of showing an empty diff that reads '
        'as "nothing changed"', () {
      final patch = parseUnifiedDiff('''
diff --git a/blob.bin b/blob.bin
new file mode 100644
index 0000000..0f49c4a
Binary files /dev/null and b/blob.bin differ
''');

      expect(patch.binary, isTrue);
      expect(patch.hunks, isEmpty);
      expect(patch.isEmpty, isFalse);
    });

    test('reads a brand-new file as all additions from line one', () {
      final patch = parseUnifiedDiff('''
diff --git a/untracked.txt b/untracked.txt
new file mode 100644
index 0000000..d5a09df
--- /dev/null
+++ b/untracked.txt
@@ -0,0 +1 @@
+brand new
''');

      expect(patch.hunks.single.rows.single.kind, DiffRowKind.added);
      expect(patch.hunks.single.rows.single.newLine, 1);
    });

    test('reads a deleted file as all removals', () {
      final patch = parseUnifiedDiff('''
diff --git a/del.txt b/del.txt
deleted file mode 100644
--- a/del.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
''');

      expect(patch.hunks.single.rows.single.kind, DiffRowKind.removed);
      expect(patch.hunks.single.rows.single.oldLine, 1);
    });

    test('an empty context line stays an empty context line, not a crash', () {
      final patch = parseUnifiedDiff('@@ -1,3 +1,3 @@\n a\n\n-b\n+B\n');

      expect(patch.hunks.single.rows[1].kind, DiffRowKind.context);
      expect(patch.hunks.single.rows[1].text, '');
    });

    test('stops at the row cap and says how many it dropped, so a generated '
        'file cannot take the window down and cannot lie about being whole', () {
      final huge = StringBuffer('@@ -1,500 +1,500 @@\n');
      for (var i = 0; i < 500; i++) {
        huge.writeln('+line $i');
      }

      final patch = parseUnifiedDiff(huge.toString(), maxRows: 100);

      expect(patch.hunks.single.rows.length, 100);
      expect(patch.truncatedBy, 400);
    });

    test('answers an empty patch for a file Git reports as unchanged', () {
      expect(parseUnifiedDiff('').isEmpty, isTrue);
    });
  });
}
