import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the process's life. A channel whose handler is deallocated stops
  /// answering, and the Appearance screen would then wait on a reply that never
  /// comes.
  private var fontsChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The messenger comes from a registrar rather than off the bridge: the
    // bridge hands out the plugin registry, and a registrar is what carries a
    // binary messenger on it.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GridFonts") {
      setUpFontsChannel(messenger: registrar.messenger())
    }
  }

  /// The channel the Appearance screen reads this phone's font families through.
  ///
  /// Same name and same reply shape as the Mac's (`grid/fonts` →
  /// `availableFamilies` → `{"all": [...], "monospaced": [...]}`), because the
  /// Dart side that turns it into picker rows is one implementation shared by
  /// both apps.
  private func setUpFontsChannel(messenger: FlutterBinaryMessenger) {
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

  /// The font families a person could reasonably pick, split by what they are
  /// for.
  ///
  /// Families whose name starts with a dot are Apple's internal faces
  /// (`.AppleSystemUIFont`, `.SFUI-Regular`): they are real, and the app uses
  /// two of them by name, but they carry no display name and several duplicate
  /// a face already listed properly. The app offers "System" as its own row
  /// instead.
  private static func availableFontFamilies() -> [String: [String]] {
    let families = UIFont.familyNames
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    return ["all": families, "monospaced": families.filter(isMonospaced)]
  }

  /// Whether a family is fixed-pitch, as the font itself declares.
  ///
  /// Asked of the family's own descriptor rather than guessed from its name: a
  /// name test ("does it say Mono?") misses Menlo and Courier and lets a symbol
  /// face through, and a symbol face offered as a code font renders source as
  /// pictograms.
  private static func isMonospaced(_ family: String) -> Bool {
    let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
    if descriptor.symbolicTraits.contains(.traitMonoSpace) { return true }

    // Some families carry the trait only on a concrete face, so ask one.
    guard let name = UIFont.fontNames(forFamilyName: family).first,
          let font = UIFont(name: name, size: 12) else { return false }
    return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
  }
}
