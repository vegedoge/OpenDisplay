import Cocoa

// MARK: - Models

struct DisplayMode {
    let width: Int
    let height: Int
    let refreshRate: Int
    let isHiDPI: Bool
    let modeNumber: Int32  // CGS mode number for switching
}

class DisplayInfo {
    let id: CGDirectDisplayID
    /// The display ID to use for mode switching (may differ from id when HiDPI virtual display is active)
    let modeTargetID: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let isMain: Bool
    let isBuiltin: Bool
    let isVirtual: Bool
    /// The physical display ID if this is a virtual display, otherwise same as id
    let physicalID: CGDirectDisplayID
    var currentMode: DisplayMode?
    var availableModes: [DisplayMode]

    init(id: CGDirectDisplayID, modeTargetID: CGDirectDisplayID, name: String,
         vendorID: UInt32, productID: UInt32,
         isMain: Bool, isBuiltin: Bool, isVirtual: Bool, physicalID: CGDirectDisplayID,
         currentMode: DisplayMode?, availableModes: [DisplayMode]) {
        self.id = id
        self.modeTargetID = modeTargetID
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.isVirtual = isVirtual
        self.physicalID = physicalID
        self.currentMode = currentMode
        self.availableModes = availableModes
    }
}

// MARK: - DisplayManager

class DisplayManager {

    // MARK: Enumeration

    func getActiveDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        return ids.map { buildDisplayInfo($0) }
    }

    private func buildDisplayInfo(_ id: CGDirectDisplayID) -> DisplayInfo {
        // Check if this active display is one of our virtual displays
        let physID = VirtualDisplayHelper.physicalID(forVirtual: id)
        let isVirtual = physID != kCGNullDirectDisplay

        let resolvedPhysicalID = isVirtual ? physID : id
        let name: String
        if isVirtual, let stored = VirtualDisplayHelper.storedName(forPhysical: physID) {
            name = stored
        } else {
            name = displayName(for: id)
        }

        let vendorID = CGDisplayVendorNumber(resolvedPhysicalID)
        let productID = CGDisplayModelNumber(resolvedPhysicalID)
        let isMain = CGDisplayIsMain(id) != 0
        let isBuiltin = CGDisplayIsBuiltin(resolvedPhysicalID) != 0

        // Modes come from the active display (virtual if HiDPI is on)
        let (current, modes) = displayModes(for: id)

        return DisplayInfo(
            id: resolvedPhysicalID,
            modeTargetID: id,
            name: name,
            vendorID: vendorID, productID: productID,
            isMain: isMain, isBuiltin: isBuiltin,
            isVirtual: isVirtual, physicalID: resolvedPhysicalID,
            currentMode: current, availableModes: modes)
    }

    private func displayName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               num == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "内置显示器" : "显示器 \(id)"
    }

    private func displayModes(for id: CGDirectDisplayID) -> (current: DisplayMode?, all: [DisplayMode]) {
        let cgsModes = CGSModeHelper.modes(forDisplay: id)

        // Dedup by (width, height, isHiDPI, hz)
        var seen = Set<String>()
        var modes: [DisplayMode] = []
        for m in cgsModes {
            let key = "\(m.width)x\(m.height)_\(m.isHiDPI)_\(m.refreshRate)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            modes.append(DisplayMode(width: Int(m.width), height: Int(m.height),
                                     refreshRate: Int(m.refreshRate),
                                     isHiDPI: m.isHiDPI, modeNumber: m.modeNumber))
        }

        let sorted = modes.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.refreshRate > b.refreshRate
        }

        // Current mode from public API
        var current: DisplayMode?
        if let cg = CGDisplayCopyDisplayMode(id) {
            let isHiDPI = cg.pixelWidth > cg.width
            let hz = Int(cg.refreshRate.rounded())
            current = DisplayMode(width: cg.width, height: cg.height,
                                  refreshRate: hz, isHiDPI: isHiDPI, modeNumber: -1)
        }

        return (current, sorted)
    }

    // MARK: Mode Switching

    func switchMode(displayID: CGDirectDisplayID, modeNumber: Int32) {
        CGSModeHelper.switchDisplay(displayID, toMode: modeNumber)
    }

    // MARK: Display Enable / Disable (using public CGDisplayCapture API)

    func setDisplayEnabled(_ displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        if enabled {
            let result = CGDisplayRelease(displayID)
            NSLog("MyDisplay: CGDisplayRelease(\(displayID)) -> \(result)")
            return result == .success
        } else {
            let result = CGDisplayCapture(displayID)
            NSLog("MyDisplay: CGDisplayCapture(\(displayID)) -> \(result)")
            return result == .success
        }
    }

    var canControlDisplayPower: Bool { true }

    // MARK: HiDPI via Virtual Display

    var isHiDPIAvailable: Bool { VirtualDisplayHelper.isAvailable() }

    func isHiDPIEnabled(for physicalID: CGDirectDisplayID) -> Bool {
        VirtualDisplayHelper.isHiDPIEnabled(forDisplay: physicalID)
    }

    func enableHiDPI(for display: DisplayInfo) {
        let native = getNativeResolution(for: display.id)
        let maxW = UInt32(max(native.width, 3840))
        let maxH = UInt32(max(native.height, 2160))

        // Detect all refresh rates the physical display supports
        let rates = getRefreshRates(for: display.id)

        VirtualDisplayHelper.enableHiDPI(forDisplay: display.id,
                                         maxWidth: maxW, maxHeight: maxH,
                                         refreshRates: rates as [NSNumber],
                                         displayName: display.name)
    }

    private func getRefreshRates(for displayID: CGDirectDisplayID) -> [Double] {
        let options = ["kCGDisplayShowDuplicateLowResolutionModes": true] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return [60.0]
        }
        // Only keep standard refresh rates to avoid bloating the virtual display
        let standard = Set([30, 48, 50, 60, 75, 90, 100, 120, 144, 165, 240])
        var seen = Set<Int>()
        var rates: [Double] = []
        for m in cgModes where m.refreshRate > 0 {
            let hz = Int(m.refreshRate.rounded())
            if standard.contains(hz) && seen.insert(hz).inserted {
                rates.append(m.refreshRate)
            }
        }
        return rates.isEmpty ? [60.0] : rates.sorted(by: >)
    }

    func disableHiDPI(for physicalID: CGDirectDisplayID) {
        VirtualDisplayHelper.disableHiDPI(forDisplay: physicalID)
    }

    func cleanupAllHiDPI() {
        VirtualDisplayHelper.removeAll()
    }

    // MARK: Native Resolution

    func getNativeResolution(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        let options = ["kCGDisplayShowDuplicateLowResolutionModes": true] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
        }
        var maxW = 0, maxH = 0
        for m in cgModes where m.pixelWidth > maxW {
            maxW = m.pixelWidth; maxH = m.pixelHeight
        }
        return maxW > 0 ? (maxW, maxH) : (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

    // MARK: - Persistence

    private func displayKey(_ d: DisplayInfo) -> String {
        "\(d.vendorID)_\(d.productID)"
    }

    func saveState(displays: [DisplayInfo]) {
        var hidpiDisplays: [String] = []
        for d in displays {
            if isHiDPIEnabled(for: d.physicalID) {
                hidpiDisplays.append(displayKey(d))
            }
        }
        UserDefaults.standard.set(hidpiDisplays, forKey: "hidpi_displays")
    }

    func saveModeForDisplay(_ display: DisplayInfo, modeNumber: Int32) {
        UserDefaults.standard.set(Int(modeNumber), forKey: "mode_\(displayKey(display))")
    }

    /// Restore HiDPI state for all connected displays. Call once on launch.
    func restoreState() {
        let savedHiDPI = UserDefaults.standard.stringArray(forKey: "hidpi_displays") ?? []
        guard !savedHiDPI.isEmpty else { return }

        let displays = getActiveDisplays()
        for display in displays {
            let key = displayKey(display)
            if savedHiDPI.contains(key) && !isHiDPIEnabled(for: display.physicalID) {
                NSLog("MyDisplay: restoring HiDPI for \(display.name) (\(key))")
                enableHiDPI(for: display)

                // Restore saved mode after HiDPI setup (needs delay for virtual display)
                if let savedMode = UserDefaults.standard.object(forKey: "mode_\(key)") as? Int {
                    let modeNum = Int32(savedMode)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        let virtualID = VirtualDisplayHelper.virtualID(forPhysical: display.id)
                        let target = virtualID != kCGNullDirectDisplay ? virtualID : display.id
                        self.switchMode(displayID: target, modeNumber: modeNum)
                        NSLog("MyDisplay: restored mode \(modeNum) for \(display.name)")
                    }
                }
            }
        }
    }
}
