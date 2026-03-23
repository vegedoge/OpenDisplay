import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dm = DisplayManager()
    private var disabledDisplays: [CGDirectDisplayID: String] = [:]

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MyDisplay")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(menu)
    }

    // MARK: Menu Construction

    private func buildMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let displays = dm.getActiveDisplays()

        for display in displays {
            addDisplaySection(display, to: menu, totalActive: displays.count)
            menu.addItem(NSMenuItem.separator())
        }

        // Disabled (captured) displays
        for (did, name) in disabledDisplays {
            let header = NSMenuItem(title: "\(name) (已关闭)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let enableItem = NSMenuItem(title: "  开启此显示器", action: #selector(onEnableDisplay(_:)), keyEquivalent: "")
            enableItem.target = self
            enableItem.tag = Int(did)
            menu.addItem(enableItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quit = NSMenuItem(title: "退出 MyDisplay", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addDisplaySection(_ display: DisplayInfo, to menu: NSMenu, totalActive: Int) {
        // Header
        let suffix = display.isMain ? " (主)" : ""
        let header = NSMenuItem(title: "\(display.name)\(suffix)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Current resolution
        if let cur = display.currentMode {
            let curHzStr = cur.refreshRate > 0 ? " @\(cur.refreshRate)Hz" : ""
            let info = NSMenuItem(title: "  当前: \(cur.width)×\(cur.height)\(curHzStr)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        // Resolution submenu
        let resSub = NSMenuItem(title: "  切换分辨率", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()
        for mode in display.availableModes {
            let hzStr = mode.refreshRate > 0 ? " @\(mode.refreshRate)Hz" : ""
            let hidpi = mode.isHiDPI ? " (HiDPI)" : ""
            let title = "\(mode.width)×\(mode.height)\(hidpi)\(hzStr)"

            let item = NSMenuItem(title: title, action: #selector(onSwitchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ModeAction(displayID: display.modeTargetID, modeNumber: mode.modeNumber)

            if let cur = display.currentMode,
               mode.width == cur.width && mode.height == cur.height
                && mode.isHiDPI == cur.isHiDPI && mode.refreshRate == cur.refreshRate {
                item.state = .on
            }
            resMenu.addItem(item)
        }
        resSub.submenu = resMenu
        menu.addItem(resSub)

        // HiDPI toggle — simple checkmark: ✓ = on
        if dm.isHiDPIAvailable {
            let enabled = dm.isHiDPIEnabled(for: display.physicalID)
            let hidpiItem = NSMenuItem(
                title: "  HiDPI",
                action: #selector(onToggleHiDPI(_:)),
                keyEquivalent: "")
            hidpiItem.target = self
            hidpiItem.state = enabled ? .on : .off
            hidpiItem.representedObject = display
            menu.addItem(hidpiItem)
        }

        // Disable display
        if totalActive > 1 && dm.canControlDisplayPower {
            let disableItem = NSMenuItem(title: "  关闭此显示器", action: #selector(onDisableDisplay(_:)), keyEquivalent: "")
            disableItem.target = self
            disableItem.representedObject = display
            menu.addItem(disableItem)
        }
    }

    // MARK: Actions

    @objc private func onSwitchMode(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ModeAction else { return }
        dm.switchMode(displayID: action.displayID, modeNumber: action.modeNumber)
    }

    @objc private func onToggleHiDPI(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        let enabled = dm.isHiDPIEnabled(for: display.physicalID)

        if enabled {
            dm.disableHiDPI(for: display.physicalID)
        } else {
            dm.enableHiDPI(for: display)
        }
    }

    @objc private func onDisableDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        disabledDisplays[display.id] = display.name
        if !dm.setDisplayEnabled(display.id, enabled: false) {
            disabledDisplays.removeValue(forKey: display.id)
            let alert = NSAlert()
            alert.messageText = "无法关闭显示器"
            alert.informativeText = "系统拒绝了此操作。"
            alert.runModal()
        }
    }

    @objc private func onEnableDisplay(_ sender: NSMenuItem) {
        let did = CGDirectDisplayID(sender.tag)
        disabledDisplays.removeValue(forKey: did)
        dm.setDisplayEnabled(did, enabled: true)
    }

    @objc private func onQuit() {
        // Re-enable captured displays
        for (did, _) in disabledDisplays {
            dm.setDisplayEnabled(did, enabled: true)
        }
        // Remove all virtual displays
        dm.cleanupAllHiDPI()
        NSApp.terminate(nil)
    }
}

class ModeAction {
    let displayID: CGDirectDisplayID
    let modeNumber: Int32
    init(displayID: CGDirectDisplayID, modeNumber: Int32) {
        self.displayID = displayID
        self.modeNumber = modeNumber
    }
}
