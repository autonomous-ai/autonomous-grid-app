import Cocoa
import FlutterMacOS
import PDFKit

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

  /// Reads the text out of a PDF the user attached to a message. PDF is not a
  /// format Dart can read, and macOS already ships a reader — so the app asks
  /// this one rather than shipping a parser of its own.
  private var documentsChannel: FlutterMethodChannel?

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

  /// Opens the channel the composer reads attached PDFs through.
  func setUpDocumentsChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "grid/documents", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pdfText":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "pdfText needs a path", details: nil))
          return
        }
        result(Self.pdfText(at: path))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    documentsChannel = channel
  }

  /// The text layer of the PDF at `path`, or nil when there isn't one.
  ///
  /// nil is a real answer, not an error: a scanned contract is a stack of
  /// pictures with no text in it, and the app tells the user that rather than
  /// sending an empty document to a model as if it had been read.
  private static func pdfText(at path: String) -> String? {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    guard let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
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
