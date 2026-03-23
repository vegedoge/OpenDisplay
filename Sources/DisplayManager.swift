import Cocoa

// MARK: - Models

struct DisplayMode {
    let width: Int
    let height: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let cgMode: CGDisplayMode
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
        let options = ["kCGDisplayShowDuplicateLowResolutionModes": true] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return (nil, [])
        }

        var best: [String: DisplayMode] = [:]
        for cg in cgModes {
            let hidpi = cg.pixelWidth > cg.width
            let key = "\(cg.width)x\(cg.height)_\(hidpi)"
            let mode = DisplayMode(width: cg.width, height: cg.height,
                                   refreshRate: cg.refreshRate, isHiDPI: hidpi, cgMode: cg)
            if let existing = best[key] {
                if mode.refreshRate > existing.refreshRate { best[key] = mode }
            } else {
                best[key] = mode
            }
        }

        let sorted = best.values.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.refreshRate > b.refreshRate
        }

        var current: DisplayMode?
        if let cg = CGDisplayCopyDisplayMode(id) {
            current = DisplayMode(width: cg.width, height: cg.height,
                                  refreshRate: cg.refreshRate,
                                  isHiDPI: cg.pixelWidth > cg.width, cgMode: cg)
        }

        return (current, sorted)
    }

    // MARK: Mode Switching

    func switchMode(displayID: CGDirectDisplayID, mode: CGDisplayMode) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
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
        // Virtual display needs to be large enough for the highest HiDPI mode.
        // For a 2560x1440 display wanting 1080p HiDPI, we need 3840x2160 rendering.
        let maxW = UInt32(max(native.width, 3840))
        let maxH = UInt32(max(native.height, 2160))
        VirtualDisplayHelper.enableHiDPI(forDisplay: display.id,
                                         maxWidth: maxW, maxHeight: maxH,
                                         displayName: display.name)
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
}
