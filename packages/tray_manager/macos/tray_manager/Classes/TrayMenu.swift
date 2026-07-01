//
//  TrayMenu.swift
//  tray_manager
//
//  Created by Lijy91 on 2022/5/8.
//

import AppKit

public class TrayMenu: NSMenu, NSMenuDelegate {
    public var onMenuItemClick:((NSMenuItem) -> Void)?
    
    public override init(title: String) {
        super.init(title: title)
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    public init(_ args: [String: Any]) {
        super.init(title: "")
        
        let items: [NSDictionary] = args["items"] as! [NSDictionary];
        for item in items {
            let menuItem: NSMenuItem
            
            let itemDict = item as! [String: Any]
            let id: Int = itemDict["id"] as! Int
            let type: String = itemDict["type"] as! String
            let label: String = itemDict["label"] as? String ?? ""
            let toolTip: String = itemDict["toolTip"] as? String ?? ""
            let checked: Bool? = itemDict["checked"] as? Bool
            let disabled: Bool = itemDict["disabled"] as? Bool ?? true
            
            if (type == "separator") {
                menuItem = NSMenuItem.separator()
            } else {
                menuItem = NSMenuItem()
            }
            
            menuItem.tag = id
            menuItem.title = label
            menuItem.toolTip = toolTip
            menuItem.isEnabled = !disabled
            menuItem.action = !disabled ? #selector(statusItemMenuButtonClicked) : nil
            menuItem.target = self

            // Render an SF Symbol icon per item when the Dart side passes one in
            // `icon`. The `checked` flag doubles as the tint selector (blue when
            // checked/active, grey otherwise) so a coloured icon — not a
            // checkmark — can signal the current selection, like the macOS
            // Wi-Fi list. Falls back to no icon on macOS < 11 (no SF Symbols).
            if let iconName = itemDict["icon"] as? String, !iconName.isEmpty,
               let image = TrayMenu.tintedSymbolImage(iconName, selected: checked == true) {
                menuItem.image = image
            }

            switch (type) {
            case "separator":
                break
            case "submenu":
                if let submenuDict = itemDict["submenu"] as? NSDictionary {
                    let submenu = TrayMenu(submenuDict as! [String : Any])
                    submenu.onMenuItemClick = { [weak self] (menuItem: NSMenuItem) in
                        guard let strongSelf = self else { return }
                        strongSelf.statusItemMenuButtonClicked(menuItem)
                    }
                    self.setSubmenu(submenu, for: menuItem)
                }
                break
            case "checkbox":
                if (checked == nil) {
                    menuItem.state = .mixed
                } else {
                    menuItem.state = checked! ? .on : .off
                }
                break
            case "switch":
                // A Control Center-style switch row (e.g. the "Grid" master
                // toggle). Needs NSSwitch (macOS 10.15+); older systems fall back
                // to a plain checkmark toggle so the item still works.
                if #available(macOS 11.0, *) {
                    let switchView = TrayMenuItemSwitchView(title: label, isOn: checked == true)
                    switchView.onToggle = { [weak self] in
                        self?.statusItemMenuButtonClicked(menuItem)
                    }
                    menuItem.view = switchView
                } else {
                    menuItem.state = (checked == true) ? .on : .off
                }
                break
            default:
                break
            }
            self.addItem(menuItem)
        }
        self.delegate = self
    }
    
    /// Builds a menu-sized SF Symbol image tinted for its state: system blue for
    /// the active item, system grey for the rest. Returns nil on macOS < 11 (no
    /// SF Symbols) or when the symbol name is unknown, so the item keeps its
    /// label without an icon.
    private static func tintedSymbolImage(_ symbolName: String, selected: Bool) -> NSImage? {
        guard #available(macOS 11.0, *) else { return nil }
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let sized = base.withSymbolConfiguration(config) ?? base
        let tint: NSColor = selected ? .systemBlue : .systemGray
        let image = NSImage(size: sized.size, flipped: false) { rect in
            sized.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc func statusItemMenuButtonClicked(_ sender: Any?) {
        if (sender is NSMenuItem && onMenuItemClick != nil) {
            let menuItem = sender as! NSMenuItem
            self.onMenuItemClick!(menuItem)
        }
    }
    
    // NSMenuDelegate
    
    public func menuDidClose(_ menu: NSMenu) {
        
    }
}
