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

    super.awakeFromNib()
  }
}
