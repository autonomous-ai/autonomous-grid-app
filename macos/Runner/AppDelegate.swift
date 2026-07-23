import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Bridges the native "Grid ▸ Check for Updates…" menu item to Flutter's
  /// AppUpdaterService, so the menu and the in-app account menu drive one
  /// Sparkle updater. Wired up by `MainFlutterWindow` once the engine exists.
  private var updaterChannel: FlutterMethodChannel?

  /// Answers Flutter's request for the families installed on this Mac, so the
  /// Appearance screen can offer the user's own fonts rather than a list this
  /// app guessed at. Flutter calls in on this one; the updater channel above
  /// goes the other way.
  private var fontsChannel: FlutterMethodChannel?

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

  /// Opens the channel the Appearance screen reads the installed fonts from.
  func setUpFontsChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "grid/fonts", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "availableFamilies":
        result(Self.availableFontFamilies())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    fontsChannel = channel
  }

  /// The font families a user could reasonably pick, split by what they are for.
  ///
  /// Returns `{"all": [...], "monospaced": [...]}` — the code picker offers only
  /// the second list. Which faces are fixed-pitch is something only the font
  /// system knows: guessing from the name ("does it contain Mono?") both misses
  /// Menlo and Courier and lets Apple Symbols through, which is exactly what
  /// went wrong — a symbol font offered as a code face renders source as
  /// pictograms.
  ///
  /// Families whose name starts with a dot are Apple's internal faces
  /// (`.AppleSystemUIFont`, `.SFNS-Regular`): they are real, and the app uses two
  /// of them by name, but they are not meant to be browsed — they carry no
  /// display name and several duplicate a face already listed properly. The app
  /// offers "System" as its own choice instead.
  private static func availableFontFamilies() -> [String: [String]] {
    let families = NSFontManager.shared.availableFontFamilies
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    let monospaced = families.filter(isMonospaced)
    return ["all": families, "monospaced": monospaced]
  }

  /// Whether a family is fixed-pitch, as the font itself declares.
  ///
  /// Asked of the family's own descriptor rather than of one concrete font: a
  /// family can carry faces that disagree, and what the picker is choosing is
  /// the family. `symbolicTraits` is the trait bit the face was built with, so
  /// this follows the type designer's answer rather than a heuristic of ours.
  private static func isMonospaced(_ family: String) -> Bool {
    let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
    if descriptor.symbolicTraits.contains(.monoSpace) { return true }

    // Some families only carry the trait on a concrete face rather than on the
    // family descriptor, so ask an instantiated font as well.
    guard let font = NSFont(descriptor: descriptor, size: 12) else { return false }
    return font.isFixedPitch
  }
}
