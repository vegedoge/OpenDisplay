import Cocoa
import ServiceManagement

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
            btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "OpenDisplay")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Restore saved configuration after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            dm.restoreState()
        }
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

        // Disabled displays: in-memory tracking + online-but-not-active + persisted builtin state
        var disabledToShow = disabledDisplays
        let activeSet = Set(displays.map { $0.id })
        for did in dm.getOnlineDisplayIDs() {
            if !activeSet.contains(did) && disabledToShow[did] == nil {
                let name = CGDisplayIsBuiltin(did) != 0 ? "内置显示器" : "显示器 \(did)"
                disabledToShow[did] = name
            }
        }
        // Built-in disabled persists across app restarts via UserDefaults
        if UserDefaults.standard.bool(forKey: "builtin_disabled") && !activeSet.contains(1) && disabledToShow[1] == nil {
            disabledToShow[1] = "内置显示器"
        }

        for (did, name) in disabledToShow {
            let header = NSMenuItem(title: "\(name) (已关闭)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let enableItem = NSMenuItem(title: "  开启此显示器", action: #selector(onEnableDisplay(_:)), keyEquivalent: "")
            enableItem.target = self
            enableItem.tag = Int(did)
            menu.addItem(enableItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Launch at login toggle
        let launchItem = NSMenuItem(title: "开机自启动", action: #selector(onToggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出 OpenDisplay", action: #selector(onQuit), keyEquivalent: "q")
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

        // HiDPI toggle — only for external displays (built-in is native Retina)
        if dm.isHiDPIAvailable && !display.isBuiltin {
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

        // Set as main display
        if !display.isMain && totalActive > 1 {
            let mainItem = NSMenuItem(title: "  设为主显示器", action: #selector(onSetMainDisplay(_:)), keyEquivalent: "")
            mainItem.target = self
            mainItem.representedObject = display
            menu.addItem(mainItem)
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

    @objc private func onSetMainDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        dm.setMainDisplay(display.modeTargetID)
        // Save preference: external display should be main
        if !display.isBuiltin {
            UserDefaults.standard.set(true, forKey: "external_is_main")
        } else {
            UserDefaults.standard.set(false, forKey: "external_is_main")
        }
    }

    @objc private func onSwitchMode(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ModeAction else { return }
        dm.switchMode(displayID: action.displayID, modeNumber: action.modeNumber)
        // Save the chosen mode for this display
        // Find the display this action belongs to
        for d in dm.getActiveDisplays() where d.modeTargetID == action.displayID {
            dm.saveModeForDisplay(d, modeNumber: action.modeNumber)
            break
        }
    }

    @objc private func onToggleHiDPI(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        let enabled = dm.isHiDPIEnabled(for: display.physicalID)

        if enabled {
            dm.disableHiDPI(for: display.physicalID)
        } else {
            dm.enableHiDPI(for: display)
        }
        // Save HiDPI state for all displays
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            dm.saveState(displays: dm.getActiveDisplays())
        }
    }

    @objc private func onDisableDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        disabledDisplays[display.id] = display.name
        dm.capturedDisplays[display.id] = display.isBuiltin
        // Persist built-in disabled state
        if display.isBuiltin {
            UserDefaults.standard.set(true, forKey: "builtin_disabled")
        }
        if !dm.setDisplayEnabled(display.id, enabled: false) {
            disabledDisplays.removeValue(forKey: display.id)
            dm.capturedDisplays.removeValue(forKey: display.id)
            let alert = NSAlert()
            alert.messageText = "无法关闭显示器"
            alert.informativeText = "系统拒绝了此操作。"
            alert.runModal()
        }
    }

    @objc private func onEnableDisplay(_ sender: NSMenuItem) {
        let did = CGDirectDisplayID(sender.tag)
        disabledDisplays.removeValue(forKey: did)
        dm.capturedDisplays.removeValue(forKey: did)
        if CGDisplayIsBuiltin(did) != 0 {
            UserDefaults.standard.set(false, forKey: "builtin_disabled")
        }
        dm.setDisplayEnabled(did, enabled: true)
    }

    @objc private func onToggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func onQuit() {
        // Re-enable captured displays
        for (did, _) in disabledDisplays {
            dm.setDisplayEnabled(did, enabled: true)
        }
        // Don't destroy virtual displays — let macOS handle cleanup.
        // This gives the best chance of display settings persisting briefly,
        // and restoreState() will re-apply on next launch.
        dm.saveState(displays: dm.getActiveDisplays())
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
