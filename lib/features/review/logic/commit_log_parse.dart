import 'review_argv.dart';
import 'review_scope.dart';

/// Reads `git log --format=%H␟%s␟%an␟%ar␞` into the commits the Committed menu
/// lists.
///
/// Control characters as delimiters, not `|` or a newline: a commit subject can
/// contain any printable character, and every printable one has already been
/// used in somebody's commit message. Git emits a newline after each record
/// too, which is why the records are trimmed rather than split on.
///
/// A record that doesn't have all four fields is skipped — a malformed line
/// must cost one commit in a menu, not the menu.
List<CommitRef> parseCommitLog(String stdout) {
  final commits = <CommitRef>[];
  for (final record in stdout.split(kLogRecordSeparator)) {
    final fields = record.trim().split(kLogFieldSeparator);
    if (fields.length < 4) continue;
    final sha = fields[0].trim();
    if (sha.isEmpty) continue;
    commits.add(
      CommitRef(
        sha: sha,
        subject: fields[1],
        author: fields[2],
        when: fields[3],
      ),
    );
  }
  return List.unmodifiable(commits);
}
