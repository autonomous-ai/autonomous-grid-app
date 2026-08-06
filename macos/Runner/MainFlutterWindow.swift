import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Let the "Grid ▸ Check for Updates…" menu action reach the Flutter updater.
    (NSApp.delegate as? AppDelegate)?
      .setUpUpdaterChannel(messenger: flutterViewController.engine.binaryMessenger)

    // Let Appearance list the fonts installed on this Mac.
    (NSApp.delegate as? AppDelegate)?
      .setUpFontsChannel(messenger: flutterViewController.engine.binaryMessenger)

    // Let the composer read the text out of an attached PDF.
    (NSApp.delegate as? AppDelegate)?
      .setUpDocumentsChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
