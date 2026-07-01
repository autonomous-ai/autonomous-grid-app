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
    private var isHighlighted = false

    init(title: String, isOn: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        autoresizingMask = [.width]

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
        isHighlighted = true
        titleLabel.textColor = .selectedMenuItemTextColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        titleLabel.textColor = .labelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedMenuItemColor.setFill()
        bounds.fill()
    }
}
