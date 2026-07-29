import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/workspace_browser.dart';
import 'package:grid_app/features/projects/logic/agent_workspace.dart';

/// The chat file browser draws whatever [flattenWorkspaceTree] returns, in order,
/// at the depth it says — so a wrong row or depth here would misdraw the tree,
/// descend into a folder the user never opened, or hide a folder still loading.
void main() {
  WorkspaceEntry dir(String path) => WorkspaceEntry(
    name: path.split('/').last,
    path: path,
    isDirectory: true,
    sizeBytes: 0,
    modified: DateTime(2020),
  );

  WorkspaceEntry file(String path, {int size = 10}) => WorkspaceEntry(
    name: path.split('/').last,
    path: path,
    isDirectory: false,
    sizeBytes: size,
    modified: DateTime(2020),
  );

  // Nothing is ever read unless the test wired that folder up.
  AsyncValue<List<WorkspaceEntry>> Function(String) childrenFrom(
    Map<String, AsyncValue<List<WorkspaceEntry>>> children,
  ) =>
      (path) => children[path] ?? const AsyncData([]);

  group('flattenWorkspaceTree', () {
    test('a closed root lists its entries at depth 0 and reads no folder', () {
      var reads = 0;
      final rows = flattenWorkspaceTree(
        rootEntries: [dir('/root/src'), file('/root/a.txt')],
        expanded: const {},
        childrenOf: (_) {
          reads++;
          return const AsyncData([]);
        },
      );

      expect(reads, 0, reason: 'a closed tree must not read any subfolder');
      expect(rows, hasLength(2));
      final folder = rows[0] as WorkspaceEntryRow;
      expect(folder.entry.path, '/root/src');
      expect(folder.depth, 0);
      expect(folder.isExpanded, isFalse);
      expect((rows[1] as WorkspaceEntryRow).entry.path, '/root/a.txt');
    });

    test('an expanded folder is marked open and its children follow at +1', () {
      final rows = flattenWorkspaceTree(
        rootEntries: [dir('/root/src'), file('/root/a.txt')],
        expanded: const {'/root/src'},
        childrenOf: childrenFrom({
          '/root/src': AsyncData([file('/root/src/main.dart')]),
        }),
      );

      expect(rows, hasLength(3));
      expect((rows[0] as WorkspaceEntryRow).isExpanded, isTrue);
      final child = rows[1] as WorkspaceEntryRow;
      expect(child.entry.path, '/root/src/main.dart');
      expect(child.depth, 1);
      // The sibling file comes after the expanded folder's whole subtree.
      expect((rows[2] as WorkspaceEntryRow).entry.path, '/root/a.txt');
    });

    test('nested expansion keeps deepening the depth', () {
      final rows = flattenWorkspaceTree(
        rootEntries: [dir('/root/a')],
        expanded: const {'/root/a', '/root/a/b'},
        childrenOf: childrenFrom({
          '/root/a': AsyncData([dir('/root/a/b')]),
          '/root/a/b': AsyncData([file('/root/a/b/c.txt')]),
        }),
      );

      expect(rows.map((r) => r.depth), [0, 1, 2]);
      expect((rows[2] as WorkspaceEntryRow).entry.path, '/root/a/b/c.txt');
    });

    test('an expanded folder still loading shows a loading status row', () {
      final rows = flattenWorkspaceTree(
        rootEntries: [dir('/root/src')],
        expanded: const {'/root/src'},
        childrenOf: childrenFrom({'/root/src': const AsyncLoading()}),
      );

      expect(rows, hasLength(2));
      final status = rows[1] as WorkspaceStatusRow;
      expect(status.isError, isFalse);
      expect(status.depth, 1);
    });

    test(
      'an expanded folder that failed to read shows an error status row',
      () {
        final rows = flattenWorkspaceTree(
          rootEntries: [dir('/root/src')],
          expanded: const {'/root/src'},
          childrenOf: childrenFrom({
            '/root/src': AsyncError(Exception('nope'), StackTrace.empty),
          }),
        );

        final status = rows[1] as WorkspaceStatusRow;
        expect(status.isError, isTrue);
        expect(status.depth, 1);
      },
    );

    test(
      'a file whose path is in the expanded set is never descended into',
      () {
        var reads = 0;
        final rows = flattenWorkspaceTree(
          rootEntries: [file('/root/a.txt')],
          // A stale path in the set must not make the browser read a file.
          expanded: const {'/root/a.txt'},
          childrenOf: (_) {
            reads++;
            return const AsyncData([]);
          },
        );

        expect(reads, 0);
        expect(rows, hasLength(1));
        expect((rows[0] as WorkspaceEntryRow).isExpanded, isFalse);
      },
    );
  });
}
