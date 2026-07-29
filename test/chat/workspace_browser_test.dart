import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/workspace_browser.dart';

/// The chat file browser must never offer a step out of the chat's own folder,
/// and its breadcrumb must land the user exactly where each crumb says — a wrong
/// path here would open the wrong folder or walk the user into the rest of the disk.
void main() {
  const root = '/Users/me/.grid/app/agent-workspace';

  group('isWithinRoot', () {
    test('a folder is within itself', () {
      expect(isWithinRoot(root, root), isTrue);
    });

    test('a trailing slash is the same folder, not a different one', () {
      expect(isWithinRoot('$root/', root), isTrue);
      expect(isWithinRoot(root, '$root/'), isTrue);
    });

    test('a child folder is within the root', () {
      expect(isWithinRoot('$root/game/assets', root), isTrue);
    });

    test('a sibling that merely shares the name prefix is not within — the '
        'guard matches folder boundaries, not string prefixes', () {
      expect(isWithinRoot('$root-backup/secret', root), isFalse);
    });

    test('a folder above the root is not within it', () {
      expect(isWithinRoot('/Users/me/.grid/app', root), isFalse);
    });
  });

  group('breadcrumbSegments', () {
    test('at the root, the trail is the root alone under its friendly label', () {
      final trail = breadcrumbSegments(
        rootPath: root,
        rootLabel: 'Workspace',
        currentPath: root,
      );
      expect(trail, [(label: 'Workspace', path: root)]);
    });

    test('drilling in names each folder and points each crumb at itself, so a '
        'tap jumps straight back up the tree', () {
      final trail = breadcrumbSegments(
        rootPath: root,
        rootLabel: 'Workspace',
        currentPath: '$root/game/assets',
      );
      expect(trail, [
        (label: 'Workspace', path: root),
        (label: 'game', path: '$root/game'),
        (label: 'assets', path: '$root/game/assets'),
      ]);
    });

    test('a current path outside the root collapses to the root — the trail '
        'never offers a step the browser would refuse to take', () {
      final trail = breadcrumbSegments(
        rootPath: root,
        rootLabel: 'Workspace',
        currentPath: '/etc/passwd',
      );
      expect(trail, [(label: 'Workspace', path: root)]);
    });

    test('a trailing slash on the current folder still reads as the root', () {
      final trail = breadcrumbSegments(
        rootPath: root,
        rootLabel: 'Workspace',
        currentPath: '$root/',
      );
      expect(trail, [(label: 'Workspace', path: root)]);
    });
  });
}
