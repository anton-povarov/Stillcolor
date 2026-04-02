//
//  Stillcolor.swift
//  Stillcolor
//
//  Created by Abdullah Arif on 26/02/2024.
//


import AppKit
import CoreGraphics
import Darwin
import os

enum DisplayLocation {
    case All
    case Embedded
    case External
}

struct DisplayTransferTable {
    let sampleCount: UInt32
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]
}

struct DisplayTransferFormula {
    let redMin: CGGammaValue
    let redMax: CGGammaValue
    let redGamma: CGGammaValue
    let greenMin: CGGammaValue
    let greenMax: CGGammaValue
    let greenGamma: CGGammaValue
    let blueMin: CGGammaValue
    let blueMax: CGGammaValue
    let blueGamma: CGGammaValue
}

enum DisplayTransferBaseline {
    case table(DisplayTransferTable)
    case formula(DisplayTransferFormula)
}

private typealias DisplayServicesGetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DisplayServicesSetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DisplayServicesCanChangeBrightnessFunction = @convention(c) (CGDirectDisplayID) -> Bool

private struct DisplayServicesBrightnessAPI {
    let handle: UnsafeMutableRawPointer
    let getBrightness: DisplayServicesGetBrightnessFunction
    let setBrightness: DisplayServicesSetBrightnessFunction
    let canChangeBrightness: DisplayServicesCanChangeBrightnessFunction?
}

class Stillcolor {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "IOKit")
    private static let softwareDimmingLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SoftwareDimming")
    private static let hardwareBrightnessLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "HardwareBrightness")
    private static let softwareBrightnessRange = 0.05...1.0
    private static let hardwareBrightnessRange = 0.05...1.0
    private static let displayTransferEpsilon: CGGammaValue = 0.0001
    private static var originalTransferBaselines: [CGDirectDisplayID: DisplayTransferBaseline] = [:]
    private static var cachedDisplayServicesBrightnessAPI: DisplayServicesBrightnessAPI?
    private static var attemptedToLoadDisplayServicesBrightnessAPI = false

    
    static func setPropertiesOnDisplayDriver(_ props : Dictionary<String, CFTypeRef>, _ targetDisplayLocation: DisplayLocation = .All) {
        var iterator = io_iterator_t()
        defer {
            IOObjectRelease(iterator);
        }
        
        /*
            IOMobileFramebufferAP is an ancestor of both AppleCLCD2 and IOMobileFramebufferShim.
            This allows us to construct 1 matching criteria for both objects
            IORegistryEntry:IOService:IOMobileFramebuffer:IOMobileFramebufferService:IOMobileFramebufferAP:UnifiedPipeline2:AppleCLCD2
            IORegistryEntry:IOService:IOMobileFramebuffer:IOMobileFramebufferService:IOMobileFramebufferAP:UnifiedPipeline2:IOMobileFramebufferShim
         
            Not sure of the exact history but M2 MacBook Air and M2 Mac mini use AppleCLCD2 (so do M1 counterparts, probably)
            While an M3 Max MBP for example uses IOMobileFramebufferShim.
            Can IOMobileFramebufferShim indicate a higher-end screen with certain attributes like PWM? Need to investigate.
         */
        let ret = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iterator)
        
        if iterator == IO_OBJECT_NULL || ret != KERN_SUCCESS {
            let message = "Could not find services matching IOMobileFramebufferAP"
            logger.error("\(message)")
            self.alert(message)
            return
        }
        
        var service: io_service_t = IO_OBJECT_NULL
        // Some code portions here are from the Monitor Control project, thanks!
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer {
            name.deallocate()
        }
        
        while true {
            service = IOIteratorNext(iterator)

            if service == 0 {
                break
            }

            do {
                defer { IOObjectRelease(service) }

                guard IORegistryEntryGetName(service, name) == KERN_SUCCESS else {
                    continue
                }
                
                let displayIsExternal = IORegistryPropertyHelper.bool("external", service) ?? false
                
                if displayIsExternal {
                    if targetDisplayLocation == .Embedded {
                        continue
                    }
                } else if targetDisplayLocation == .External {
                    continue
                }

                // IORegistryEntrySetCFProperties does not work properly here- only the first porperty gets modified
                // So we need to set them individually
                for (propKey, newVal) in props {
                    
                    if CFEqual(newVal, IORegistryPropertyHelper.CFValueForKey(propKey, service)) {
                        continue
                    }
                    
                    let ret = IORegistryEntrySetCFProperty(service, propKey as CFString, newVal)
                    
                    logger.info("Setting I/O Registry property \(String(propKey)) = \(String(describing: newVal)) on \(displayIsExternal ? "external": "embedded") display -> \"\(String(cString: mach_error_string(ret)))\"")
                }
            }
        }
    }

    static func enableDisableDithering(_ disable: Bool) {
        setPropertiesOnDisplayDriver([
            "enableDither": CFBooleanFromBool(!disable)
        ])
    }
    
    static func enableDisableUniformity2D(_ disable: Bool) {
        setPropertiesOnDisplayDriver([
            "uniformity2D": CFBooleanFromBool(!disable)
        ], .Embedded)
    }

    static func enableDisableSoftwareDimming(_ enable: Bool, brightness: Double? = nil) {
        guard enable else {
            restoreSoftwareDimming()
            return
        }

        applySoftwareDimming(brightness: brightness ?? 1.0)
    }

    static func setSoftwareBrightness(_ brightness: Double) {
        applySoftwareDimming(brightness: brightness)
    }

    static func recaptureSoftwareDimmingBaseline(brightness: Double? = nil) {
        CGDisplayRestoreColorSyncSettings()
        originalTransferBaselines.removeAll()

        if let brightness {
            applySoftwareDimming(brightness: brightness)
        }
    }

    static func restoreSoftwareDimming() {
        guard !originalTransferBaselines.isEmpty else {
            return
        }

        for (displayID, baseline) in originalTransferBaselines {
            let result = restoreTransferBaseline(baseline, on: displayID)
            if result != .success {
                softwareDimmingLogger.error("Failed to restore software dimming for display \(displayID): \(result.rawValue)")
            }
        }

        originalTransferBaselines.removeAll()
    }

    static func setHardwareBrightnessToSavedPreference() {
        let storedBrightness = UserDefaults.standard.object(forKey: "hardwareBrightness") as? Double ?? hardwareBrightnessRange.upperBound
        setHardwareBrightness(storedBrightness)
    }

    static func setHardwareBrightnessToMax() {
        setHardwareBrightness(hardwareBrightnessRange.upperBound)
    }

    static func setHardwareBrightness(_ brightness: Double) {
        guard let api = loadDisplayServicesBrightnessAPI() else {
            hardwareBrightnessLogger.error("DisplayServices brightness API unavailable")
            return
        }

        let clampedBrightness = min(max(brightness, hardwareBrightnessRange.lowerBound), hardwareBrightnessRange.upperBound)
        let displays = builtInDisplays()
        guard !displays.isEmpty else {
            hardwareBrightnessLogger.error("No built-in displays available for hardware brightness control")
            return
        }

        for displayID in displays {
            if let canChangeBrightness = api.canChangeBrightness, !canChangeBrightness(displayID) {
                hardwareBrightnessLogger.info("Skipping display \(displayID): hardware brightness control not available")
                continue
            }

            let result = api.setBrightness(displayID, Float(clampedBrightness))
            if result != 0 {
                hardwareBrightnessLogger.error("Failed to set hardware brightness for display \(displayID) to \(clampedBrightness): \(result)")
            } else {
                hardwareBrightnessLogger.debug("Set hardware brightness for display \(displayID) to \(clampedBrightness)")
            }
        }
    }

    static func refreshSavedHardwareBrightnessFromCurrentDisplay() -> Double? {
        guard let currentBrightness = currentHardwareBrightnessValue() else {
            return nil
        }

        let clampedBrightness = min(max(currentBrightness, hardwareBrightnessRange.lowerBound), hardwareBrightnessRange.upperBound)
        UserDefaults.standard.set(clampedBrightness, forKey: "hardwareBrightness")
        return clampedBrightness
    }

    static func currentHardwareBrightnessValue() -> Double? {
        currentHardwareBrightness()
    }

    static func applyCurrentPreferences() {
        let defaults = UserDefaults.standard
        enableDisableDithering(defaults.bool(forKey: "disableDithering"))
        enableDisableUniformity2D(defaults.bool(forKey: "disableUniformity2D"))
        setHardwareBrightnessToSavedPreference()
        enableDisableSoftwareDimming(
            defaults.bool(forKey: "enableSoftwareDimming"),
            brightness: defaults.object(forKey: "softwareBrightness") as? Double ?? 1.0
        )
    }
    
    static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Stillcolor Issue"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .critical
        alert.runModal()
    }
    
    //MARK: - CF utils
    
    static func CFBooleanFromBool(_ value : Bool) -> CFBoolean {
        return value ? kCFBooleanTrue : kCFBooleanFalse
    }
    
    static func CFNumberFromInteger(_ value: UInt32) -> CFNumber {
        return NSNumber(value: value) as CFNumber
    }

    private static func loadDisplayServicesBrightnessAPI() -> DisplayServicesBrightnessAPI? {
        if let api = cachedDisplayServicesBrightnessAPI {
            return api
        }

        if attemptedToLoadDisplayServicesBrightnessAPI {
            return nil
        }
        attemptedToLoadDisplayServicesBrightnessAPI = true

        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let message = String(cString: dlerror())
            hardwareBrightnessLogger.error("Failed to load DisplayServices framework: \(message)")
            return nil
        }

        guard
            let getBrightnessSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
            let setBrightnessSymbol = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown symbol lookup failure"
            hardwareBrightnessLogger.error("DisplayServices brightness symbols unavailable: \(message)")
            return nil
        }

        let api = DisplayServicesBrightnessAPI(
            handle: handle,
            getBrightness: unsafeBitCast(getBrightnessSymbol, to: DisplayServicesGetBrightnessFunction.self),
            setBrightness: unsafeBitCast(setBrightnessSymbol, to: DisplayServicesSetBrightnessFunction.self),
            canChangeBrightness: dlsym(handle, "DisplayServicesCanChangeBrightness").map {
                unsafeBitCast($0, to: DisplayServicesCanChangeBrightnessFunction.self)
            }
        )
        cachedDisplayServicesBrightnessAPI = api
        return api
    }

    private static func currentHardwareBrightness() -> Double? {
        guard let api = loadDisplayServicesBrightnessAPI() else {
            hardwareBrightnessLogger.error("DisplayServices brightness API unavailable for reading")
            return nil
        }

        let displays = builtInDisplays()
        guard !displays.isEmpty else {
            hardwareBrightnessLogger.error("No built-in displays available for hardware brightness read")
            return nil
        }

        for displayID in displays {
            if let canChangeBrightness = api.canChangeBrightness, !canChangeBrightness(displayID) {
                continue
            }

            var brightness: Float = 0
            let result = api.getBrightness(displayID, &brightness)
            if result == 0 {
                return Double(brightness)
            }

            hardwareBrightnessLogger.error("Failed to read hardware brightness for display \(displayID): \(result)")
        }

        return nil
    }

    private static func applySoftwareDimming(brightness: Double) {
        let clampedBrightness = min(max(brightness, softwareBrightnessRange.lowerBound), softwareBrightnessRange.upperBound)
        let displays = builtInDisplays()

        if displays.isEmpty {
            softwareDimmingLogger.error("No built-in displays available for software dimming")
            return
        }

        for displayID in displays {
            guard let baseline = originalTransferBaseline(for: displayID) else {
                continue
            }

            let result = applyTransferBaseline(baseline, on: displayID, brightness: clampedBrightness)
            if result != .success {
                softwareDimmingLogger.error("Failed to apply software dimming to display \(displayID): \(result.rawValue)")
            }
        }
    }

    private static func originalTransferBaseline(for displayID: CGDirectDisplayID) -> DisplayTransferBaseline? {
        if let cachedBaseline = originalTransferBaselines[displayID] {
            return cachedBaseline
        }

        if let table = originalTransferTable(for: displayID) {
            let baseline = DisplayTransferBaseline.table(table)
            originalTransferBaselines[displayID] = baseline
            return baseline
        }

        if let formula = originalTransferFormula(for: displayID) {
            let baseline = DisplayTransferBaseline.formula(formula)
            originalTransferBaselines[displayID] = baseline
            return baseline
        }

        softwareDimmingLogger.error("No transfer baseline available for display \(displayID)")
        return nil
    }

    private static func originalTransferTable(for displayID: CGDirectDisplayID) -> DisplayTransferTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)

        guard capacity > 0 else {
            return nil
        }

        var redTable = [CGGammaValue](repeating: 0, count: Int(capacity))
        var greenTable = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blueTable = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0

        let result = redTable.withUnsafeMutableBufferPointer { redBuffer in
            greenTable.withUnsafeMutableBufferPointer { greenBuffer in
                blueTable.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        capacity,
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress,
                        &sampleCount
                    )
                }
            }
        }

        guard result == .success, sampleCount > 0 else {
            softwareDimmingLogger.info("Display \(displayID) transfer table unavailable, falling back to formula: \(result.rawValue)")
            return nil
        }

        let samplePrefix = Int(sampleCount)
        return DisplayTransferTable(
            sampleCount: sampleCount,
            red: Array(redTable.prefix(samplePrefix)),
            green: Array(greenTable.prefix(samplePrefix)),
            blue: Array(blueTable.prefix(samplePrefix))
        )
    }

    private static func originalTransferFormula(for displayID: CGDirectDisplayID) -> DisplayTransferFormula? {
        var redMin: CGGammaValue = 0
        var redMax: CGGammaValue = 0
        var redGamma: CGGammaValue = 0
        var greenMin: CGGammaValue = 0
        var greenMax: CGGammaValue = 0
        var greenGamma: CGGammaValue = 0
        var blueMin: CGGammaValue = 0
        var blueMax: CGGammaValue = 0
        var blueGamma: CGGammaValue = 0

        let result = CGGetDisplayTransferByFormula(
            displayID,
            &redMin, &redMax, &redGamma,
            &greenMin, &greenMax, &greenGamma,
            &blueMin, &blueMax, &blueGamma
        )

        guard result == .success else {
            softwareDimmingLogger.error("Failed to read software dimming baseline for display \(displayID): \(result.rawValue)")
            return nil
        }

        let formula = DisplayTransferFormula(
            redMin: redMin,
            redMax: redMax,
            redGamma: redGamma,
            greenMin: greenMin,
            greenMax: greenMax,
            greenGamma: greenGamma,
            blueMin: blueMin,
            blueMax: blueMax,
            blueGamma: blueGamma
        )
        return formula
    }

    private static func applyTransferBaseline(
        _ baseline: DisplayTransferBaseline,
        on displayID: CGDirectDisplayID,
        brightness: Double
    ) -> CGError {
        switch baseline {
        case .table(let table):
            return setDisplayTransferTable(
                displayID,
                table: scaledTransferTable(table, brightness: brightness)
            )
        case .formula(let formula):
            return CGSetDisplayTransferByFormula(
                displayID,
                formula.redMin,
                scaledMaximum(for: formula.redMin, originalMaximum: formula.redMax, brightness: brightness),
                formula.redGamma,
                formula.greenMin,
                scaledMaximum(for: formula.greenMin, originalMaximum: formula.greenMax, brightness: brightness),
                formula.greenGamma,
                formula.blueMin,
                scaledMaximum(for: formula.blueMin, originalMaximum: formula.blueMax, brightness: brightness),
                formula.blueGamma
            )
        }
    }

    private static func restoreTransferBaseline(
        _ baseline: DisplayTransferBaseline,
        on displayID: CGDirectDisplayID
    ) -> CGError {
        switch baseline {
        case .table(let table):
            return setDisplayTransferTable(displayID, table: table)
        case .formula(let formula):
            return CGSetDisplayTransferByFormula(
                displayID,
                formula.redMin, formula.redMax, formula.redGamma,
                formula.greenMin, formula.greenMax, formula.greenGamma,
                formula.blueMin, formula.blueMax, formula.blueGamma
            )
        }
    }

    private static func scaledTransferTable(_ table: DisplayTransferTable, brightness: Double) -> DisplayTransferTable {
        let factor = CGGammaValue(brightness)

        return DisplayTransferTable(
            sampleCount: table.sampleCount,
            red: table.red.map { clampTransferSample($0 * factor) },
            green: table.green.map { clampTransferSample($0 * factor) },
            blue: table.blue.map { clampTransferSample($0 * factor) }
        )
    }

    private static func setDisplayTransferTable(_ displayID: CGDirectDisplayID, table: DisplayTransferTable) -> CGError {
        let red = table.red
        let green = table.green
        let blue = table.blue

        return red.withUnsafeBufferPointer { redBuffer in
            green.withUnsafeBufferPointer { greenBuffer in
                blue.withUnsafeBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        table.sampleCount,
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }
    }

    private static func builtInDisplays() -> [CGDirectDisplayID] {
        let maxDisplays: UInt32 = 16
        var activeDisplayCount: UInt32 = 0
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))

        let result = CGGetOnlineDisplayList(maxDisplays, &activeDisplays, &activeDisplayCount)

        guard result == .success else {
            softwareDimmingLogger.error("Failed to enumerate displays for software dimming: \(result.rawValue)")
            return []
        }

        return activeDisplays
            .prefix(Int(activeDisplayCount))
            .filter { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsOnline($0) != 0 }
    }

    private static func scaledMaximum(
        for originalMinimum: CGGammaValue,
        originalMaximum: CGGammaValue,
        brightness: Double
    ) -> CGGammaValue {
        let scaledMaximum = originalMinimum + ((originalMaximum - originalMinimum) * CGGammaValue(brightness))
        return max(scaledMaximum, originalMinimum + displayTransferEpsilon)
    }

    private static func clampTransferSample(_ sample: CGGammaValue) -> CGGammaValue {
        min(max(sample, 0), 1)
    }
}
