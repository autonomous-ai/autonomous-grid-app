import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_browser.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_browser_access.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';

BrowserAccess accessWith({
  String model = 'claude:opus',
  ChromeExtensionState extensionState = ChromeExtensionState.ready,
  bool cliSupportsChrome = true,
  bool hasChrome = true,
  bool hasNodeRunner = true,
  bool cdpAllowed = true,
}) => describeBrowserAccess(
  model: model,
  extensionState: extensionState,
  cliSupportsChrome: cliSupportsChrome,
  hasChrome: hasChrome,
  hasNodeRunner: hasNodeRunner,
  cdpAllowed: cdpAllowed,
);

void main() {
  group('what the browser card tells the user', () {
    test('a ready extension says the assistant is in the browser they already '
        'use, which is the only lane that carries their logins', () {
      final access = accessWith();
      expect(access.lane, ClaudeBrowserLane.extension);
      expect(access.title, 'Works in your Chrome');
      expect(access.step, isNull);
    });

    test('a missing extension offers the store, so the fix is a click and not '
        'a support thread', () {
      final access = accessWith(extensionState: ChromeExtensionState.missing);
      expect(access.step, BrowserSetupStep.installExtension);
      expect(access.detail, contains('Claude in Chrome'));
    });

    test('an extension no browser has connected yet asks for the one thing the '
        'app cannot do — the restart — and keeps the retry beside it', () {
      final access = accessWith(
        extensionState: ChromeExtensionState.hostPending,
      );
      expect(access.step, BrowserSetupStep.connectChrome);
      expect(access.detail, contains('open Chrome'));
    });

    test('a grid model is told to switch model, and offered no button the card '
        'cannot honour', () {
      final access = accessWith(model: 'qwen3-coder-30b');
      expect(access.lane, ClaudeBrowserLane.cdp);
      expect(access.detail, contains('pick a Claude model'));
      expect(access.step, isNull);
    });

    test('an old Claude Code points at the update button above it rather than '
        'at the extension, which is not what is wrong', () {
      final access = accessWith(cliSupportsChrome: false);
      expect(access.detail, contains('Update Claude Code'));
      expect(access.step, isNull);
    });

    test('the fallback names what it costs: a window signed in to nothing, so '
        'nobody expects it to reach their ad account', () {
      final access = accessWith(extensionState: ChromeExtensionState.missing);
      expect(access.lane, ClaudeBrowserLane.cdp);
      expect(access.detail, contains('signed in to nothing'));
    });

    test('with the switch off the card says nothing opens a browser, and still '
        'shows the way into their own one', () {
      final access = accessWith(
        extensionState: ChromeExtensionState.missing,
        cdpAllowed: false,
      );
      expect(access.lane, ClaudeBrowserLane.none);
      expect(access.detail, startsWith('Nothing here opens a browser'));
      expect(access.step, BrowserSetupStep.installExtension);
    });

    test('a computer with no Chrome at all names Chrome, not Node', () {
      final access = accessWith(
        extensionState: ChromeExtensionState.missing,
        hasChrome: false,
      );
      expect(access.lane, ClaudeBrowserLane.none);
      expect(access.detail, contains('no Chrome on this computer'));
    });

    test('a computer with Chrome but no Node names Node — the two dead ends '
        'have different fixes', () {
      final access = accessWith(
        extensionState: ChromeExtensionState.missing,
        hasNodeRunner: false,
      );
      expect(access.lane, ClaudeBrowserLane.none);
      expect(access.detail, contains('Node.js'));
    });

    test(
      'the lane always matches the one the next turn would take, so the card '
      'can never promise a browser the turn drops',
      () {
        const states = ChromeExtensionState.values;
        for (final state in states) {
          for (final allowed in [true, false]) {
            final access = accessWith(
              extensionState: state,
              cdpAllowed: allowed,
            );
            final plan = planClaudeBrowser(
              model: 'claude:opus',
              extensionState: state,
              cliSupportsChrome: true,
              cdpReady: true,
              cdpAllowed: allowed,
            );
            expect(access.lane, plan.lane);
          }
        }
      },
    );
  });
}
