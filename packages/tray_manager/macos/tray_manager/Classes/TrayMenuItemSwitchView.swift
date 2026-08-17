//
//  TrayMenuItemSwitchView.swift
//  tray_manager
//
//  A menu-item content view that renders a title on the left and a Control
//  Center-style switch on the right — the "Grid on/off" master toggle, so the
//  tray reads like the macOS Wi-Fi / Bluetooth menus.
//

import AppKit

/// The switch row shown at the top of the tray menu. The whole row is the hit
/// target — the `NSSwitch` is visual only, because a control's own target/action
/// is unreliable inside a menu's modal event tracking. Flipping it updates the
/// switch, closes the menu (like any command), then fires [onToggle].
@available(macOS 10.15, *)
class TrayMenuItemSwitchView: NSView {
    /// Fired after the user flips the switch, so the Dart side can react (e.g.
    /// stop the running engine). The visual state is flipped optimistically; the
    /// menu is rebuilt with the real state next time it opens.
    var onToggle: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    /// The hover highlight behind the row.
    ///
    /// A visual-effect view rather than a colour filled in `draw`:
    /// `NSColor.selectedMenuItemColor` was deprecated in macOS 11 in favour of
    /// the `.selection` material, which is what a real menu row wears — vibrant
    /// over whatever the menu sits on, and following the user's accent colour,
    /// where a flat fill could only imitate one of the two.
    private let highlight = NSVisualEffectView()

    init(title: String, isOn: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        autoresizingMask = [.width]

        highlight.material = .selection
        highlight.blendingMode = .behindWindow
        // `.selection` draws grey until the view is emphasized — that flag is
        // the whole difference between "a highlighted row" and "a grey box".
        highlight.isEmphasized = true
        highlight.state = .active
        highlight.isHidden = true
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        // Added first, so the label and the switch draw over it.
        addSubview(highlight)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = title
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)

        toggle.state = isOn ? .on : .off
        toggle.target = nil
        toggle.action = nil
        addSubview(toggle)

        // `.inVisibleRect` tracks the live bounds, so the hover highlight follows
        // the row as the menu lays it out.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 14
        let switchSize = toggle.intrinsicContentSize
        toggle.frame = NSRect(
            x: bounds.width - padding - switchSize.width,
            y: (bounds.height - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height)
        let labelHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: padding,
            y: (bounds.height - labelHeight) / 2,
            width: max(0, toggle.frame.minX - padding * 2),
            height: labelHeight)
    }

    /// Route every click to the row itself, so menu tracking delivers a reliable
    /// `mouseUp` we act on — the switch never steals the event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        toggle.state = toggle.state == .on ? .off : .on
        onToggle?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.isHidden = false
        titleLabel.textColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.isHidden = true
        titleLabel.textColor = .labelColor
    }
}
