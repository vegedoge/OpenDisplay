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

    // MARK: Mode Cache (avoid re-enumerating 160+ modes on every menu open)
    private var modeCache: [CGDirectDisplayID: [DisplayMode]] = [:]
    private var modeCacheDirty = true

    /// Track displays we disabled, with whether they were built-in at capture time
    var capturedDisplays: [CGDirectDisplayID: Bool] = [:]  // displayID -> isBuiltin

    /// Debounce timer for main display restoration
    private var mainDisplayTimer: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.modeCacheDirty = true
            self?.modeCache.removeAll()

            // Debounced main display check — runs 4s after the LAST config change
            self?.scheduleMainDisplayCheck()

            let cleanedPhysicalIDs = VirtualDisplayHelper.cleanupDisconnectedDisplays() as? [NSNumber] ?? []

            if !cleanedPhysicalIDs.isEmpty {
                let physIDs = cleanedPhysicalIDs.map { $0.uint32Value }
                // Virtual display was removed (external went offline).
                // Wait 3s then check: if that specific physical display didn't come back,
                // re-enable built-in. During sleep, asyncAfter is paused — it only fires
                // after wake, at which point the external is back online → built-in stays off.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.reenableBuiltinIfExternalGone(physicalIDs: physIDs)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.restoreHiDPIForReconnectedDisplays()
            }
        }

        // On wake: reapply saved modes (macOS may have reset them)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.reapplySavedModes()
                }
            }
        }
    }

    /// Re-enable built-in display if no external display is active.
    /// Called with delay after cleanup — if system was just sleeping,
    /// external will be back by now so this is a no-op.
    /// Check if the specific physical displays that went offline are still gone.
    /// If they are, re-enable built-in. If they came back (sleep/wake), do nothing.
    private func reenableBuiltinIfExternalGone(physicalIDs: [UInt32]) {
        let onlineIDs = Set(getOnlineDisplayIDs())

        let anyPhysicalBack = physicalIDs.contains { onlineIDs.contains($0) }

        NSLog("OpenDisplay: reenableCheck — looking for physical \(physicalIDs), online=\(Array(onlineIDs)), back=\(anyPhysicalBack)")

        if anyPhysicalBack {
            NSLog("OpenDisplay: physical display reconnected (sleep/wake), keeping built-in disabled")
        } else {
            NSLog("OpenDisplay: physical display truly gone, re-enabling built-in")
            _ = setDisplayEnabled(1, enabled: true)
        }
    }

    /// Restore HiDPI for external displays that were reconnected,
    /// and re-disable built-in if it was previously disabled by the user.
    private func restoreHiDPIForReconnectedDisplays() {
        let savedHiDPI = UserDefaults.standard.stringArray(forKey: "hidpi_displays") ?? []
        let builtinShouldBeDisabled = UserDefaults.standard.bool(forKey: "builtin_disabled")
        var didRestoreExternal = false

        for display in getActiveDisplays() {
            if display.isBuiltin { continue }
            let key = displayKey(display)
            if savedHiDPI.contains(key) && !isHiDPIEnabled(for: display.physicalID) {
                NSLog("OpenDisplay: restoring HiDPI for reconnected \(display.name)")
                enableHiDPI(for: display)
                didRestoreExternal = true
                if let savedMode = UserDefaults.standard.object(forKey: "mode_\(key)") as? Int {
                    let modeNum = Int32(savedMode)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
                        let vid = VirtualDisplayHelper.virtualID(forPhysical: display.id)
                        let target = vid != kCGNullDirectDisplay ? vid : display.id
                        let validModes = CGSModeHelper.modes(forDisplay: target)
                        guard validModes.contains(where: { $0.modeNumber == modeNum }) else { return }
                        switchMode(displayID: target, modeNumber: modeNum)
                    }
                }
            }
        }

        if didRestoreExternal {
            // Restore main display + built-in disabled state after HiDPI settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
                // Restore external as main display if it was before
                if UserDefaults.standard.bool(forKey: "external_is_main") {
                    for d in getActiveDisplays() where !d.isBuiltin {
                        NSLog("OpenDisplay: restoring external as main display")
                        setMainDisplay(d.modeTargetID)
                        break
                    }
                }
                // Re-disable built-in if user had it disabled
                if builtinShouldBeDisabled {
                    NSLog("OpenDisplay: re-disabling built-in display (user preference)")
                    _ = setDisplayEnabled(1, enabled: false)
                }
            }
        }
    }

    /// Reapply saved display modes and main display preference after wake
    private func reapplySavedModes() {
        for display in getActiveDisplays() {
            if display.isBuiltin { continue }
            let key = displayKey(display)

            // If HiDPI should be on but isn't, restore it
            let savedHiDPI = UserDefaults.standard.stringArray(forKey: "hidpi_displays") ?? []
            if savedHiDPI.contains(key) && !isHiDPIEnabled(for: display.physicalID) {
                NSLog("OpenDisplay: wake — restoring HiDPI for \(display.name)")
                enableHiDPI(for: display)
            }

            // Reapply saved mode
            if let savedMode = UserDefaults.standard.object(forKey: "mode_\(key)") as? Int {
                let modeNum = Int32(savedMode)
                let target = display.modeTargetID
                if let cur = display.currentMode, cur.modeNumber != modeNum {
                    let validModes = CGSModeHelper.modes(forDisplay: target)
                    guard validModes.contains(where: { $0.modeNumber == modeNum }) else { continue }
                    NSLog("OpenDisplay: wake — reapplying mode \(modeNum) for \(display.name)")
                    switchMode(displayID: target, modeNumber: modeNum)
                }
            }
        }

        // Restore main display preference
        if UserDefaults.standard.bool(forKey: "external_is_main") {
            for d in getActiveDisplays() where !d.isBuiltin {
                if !d.isMain {
                    NSLog("OpenDisplay: wake — restoring external as main display")
                    setMainDisplay(d.modeTargetID)
                }
                break
            }
        }
    }

    /// Debounced main display check — waits for display config to settle,
    /// then restores external as main if the user preference says so.
    /// Each call cancels the previous timer, so rapid config changes only trigger once.
    private func scheduleMainDisplayCheck() {
        mainDisplayTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard UserDefaults.standard.bool(forKey: "external_is_main") else { return }
            for d in getActiveDisplays() where !d.isBuiltin {
                if !d.isMain {
                    NSLog("OpenDisplay: restoring external as main display (debounced)")
                    setMainDisplay(d.modeTargetID)
                }
                break
            }
        }
        mainDisplayTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    // MARK: Enumeration

    /// All physically connected display IDs (includes disabled ones)
    func getOnlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids
    }

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
        // Use cached modes if available
        if let cached = modeCache[id] {
            let current = currentMode(for: id)
            return (current, cached)
        }

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

        modeCache[id] = sorted
        let current = currentMode(for: id)
        return (current, sorted)
    }

    private func currentMode(for id: CGDirectDisplayID) -> DisplayMode? {
        guard let cg = CGDisplayCopyDisplayMode(id) else { return nil }
        let isHiDPI = cg.pixelWidth > cg.width
        let hz = Int(cg.refreshRate.rounded())
        return DisplayMode(width: cg.width, height: cg.height,
                           refreshRate: hz, isHiDPI: isHiDPI, modeNumber: -1)
    }

    // MARK: Mode Switching

    func switchMode(displayID: CGDirectDisplayID, modeNumber: Int32) {
        CGSModeHelper.switchDisplay(displayID, toMode: modeNumber)
    }

    // MARK: Set Main Display

    func setMainDisplay(_ displayID: CGDirectDisplayID) {
        // Main display = origin (0,0). Move target to (0,0) and shift others.
        let targetBounds = CGDisplayBounds(displayID)

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }

        for id in ids {
            let bounds = CGDisplayBounds(id)
            let newX = Int32(bounds.origin.x - targetBounds.origin.x)
            let newY = Int32(bounds.origin.y - targetBounds.origin.y)
            CGConfigureDisplayOrigin(config, id, newX, newY)
        }

        CGCompleteDisplayConfiguration(config, .permanently)
    }

    // MARK: Display Enable / Disable via CGSConfigureDisplayEnabled

    func setDisplayEnabled(_ displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        return CGSDisplayHelper.setDisplay(displayID, enabled: enabled)
    }

    var canControlDisplayPower: Bool { CGSDisplayHelper.isAvailable() }

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
                NSLog("OpenDisplay: restoring HiDPI for \(display.name) (\(key))")
                enableHiDPI(for: display)

                // Restore saved mode after HiDPI setup (needs delay for virtual display)
                if let savedMode = UserDefaults.standard.object(forKey: "mode_\(key)") as? Int {
                    let modeNum = Int32(savedMode)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        let virtualID = VirtualDisplayHelper.virtualID(forPhysical: display.id)
                        let target = virtualID != kCGNullDirectDisplay ? virtualID : display.id
                        let validModes = CGSModeHelper.modes(forDisplay: target)
                        guard validModes.contains(where: { $0.modeNumber == modeNum }) else { return }
                        self.switchMode(displayID: target, modeNumber: modeNum)
                        NSLog("OpenDisplay: restored mode \(modeNum) for \(display.name)")
                    }
                }
            }
        }
    }
}
