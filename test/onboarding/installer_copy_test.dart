import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/onboarding/logic/installer_controller.dart';
import 'package:grid_app/features/onboarding/logic/installer_copy.dart';

/// The installer header is the only thing on screen while setup runs, so what it
/// says has to track what is actually happening — a headline that keeps implying
/// work after a failure is the screen lying to a first-time user.
void main() {
  group('installer header copy', () {
    test('a failure stops claiming setup is under way', () {
      const state = InstallerFailed();
      expect(installerHeadline(state), isNot(contains('Setting up')));
      expect(installerSubtitle(state), contains('try again'));
    });

    test('finishing says so, and points at the next decision', () {
      expect(installerHeadline(const InstallerDone()), 'Ready');
      expect(installerSubtitle(const InstallerDone()), contains('model'));
    });

    test('while it runs it promises only that it is quick — never a model '
        'download, which only the "run local" choice starts', () {
      expect(installerHeadline(const InstallerRunning()), 'Setting up your AI');
      expect(
        installerSubtitle(const InstallerRunning()),
        isNot(contains('download')),
      );
    });
  });
}
