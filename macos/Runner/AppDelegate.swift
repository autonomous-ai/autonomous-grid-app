import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Bridges the native "Grid ▸ Check for Updates…" menu item to Flutter's
  /// AppUpdaterService, so the menu and the in-app account menu drive one
  /// Sparkle updater. Wired up by `MainFlutterWindow` once the engine exists.
  private var updaterChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Opens the channel Flutter listens on for menu-driven update checks.
  func setUpUpdaterChannel(messenger: FlutterBinaryMessenger) {
    updaterChannel = FlutterMethodChannel(name: "grid/app_updater", binaryMessenger: messenger)
  }

  /// Action for the app-menu item (First Responder target). Forwards to Flutter;
  /// AppUpdaterService.checkForUpdates handles the feed/enabled gate.
  @objc func checkForUpdatesFromMenu(_ sender: Any?) {
    updaterChannel?.invokeMethod("checkForUpdates", arguments: nil)
  }
}
