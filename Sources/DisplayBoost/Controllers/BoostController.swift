import AppKit
import CoreGraphics
import OSLog

enum BoostSuspensionReason: Hashable {
    case systemSleep
    case screenSleep
    case inactiveSession
}

@MainActor
final class BoostController {
    private static let nativeBrightnessMaximumThreshold: Float = 0.995

    private enum DefaultsKey {
        static let level = "boostLevel"
        static let recoveryRequired = "recoveryRequired"
        static let savedNativeBrightness = "savedNativeBrightness"
    }

    private let gamma = GammaTableService()
    private let edrTrigger = EDRTriggerService()
    private let nativeBrightness = NativeBrightnessService()
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "local.jjxu.DisplayBoost", category: "Recovery")

    private var wantedActive = false
    private var suspensionReasons: Set<BoostSuspensionReason> = []
    private var savedNativeBrightness: Float?
    private var activeDisplayID: CGDirectDisplayID?
    private var activeColorProfileIdentity: ColorProfileIdentity?
    private var backlightPinnedForBoost = false
    private var gammaRecoveryHandled = false
    private var engagementGeneration = 0
    private var resumePending = false
    private var resumeBrightnessBaseline: Float?
    private var integrityTimer: Timer?

    private(set) var state: BoostState = .off
    private(set) var level: BoostLevel
    var onSnapshot: ((BoostSnapshot) -> Void)?

    init() {
        let stored = defaults.object(forKey: DefaultsKey.level) as? NSNumber
        level = BoostLevel(stored?.floatValue ?? BoostLevel.defaultValue)

        if let saved = defaults.object(
            forKey: DefaultsKey.savedNativeBrightness
        ) as? NSNumber {
            savedNativeBrightness = saved.floatValue
        }

        let needsRecovery = defaults.bool(forKey: DefaultsKey.recoveryRequired) ||
            savedNativeBrightness != nil
        if needsRecovery {
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
            if !recoverInterruptedSession() {
                state = .unavailable("等待内置显示器恢复标准亮度")
            }
        }

        startIntegrityTimer()
    }

    deinit {
        integrityTimer?.invalidate()
    }

    var snapshot: BoostSnapshot {
        let screen = DisplayLookup.builtInScreen
        return BoostSnapshot(
            state: state,
            level: level,
            currentEDRHeadroom: Double(
                screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
            ),
            potentialEDRHeadroom: Double(
                screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
            )
        )
    }

    func toggle() {
        if wantedActive {
            disable()
        } else {
            enable()
        }
    }

    func enable() {
        if wantedActive && state == .active { return }
        resumePending = false
        resumeBrightnessBaseline = nil
        if level.factor <= BoostLevel.minimum {
            let firstBoostStep = BrightnessKeyStep.nextBoostLevel(
                from: BoostLevel.minimum,
                direction: .increase,
                fineGrained: false
            )
            setLevel(firstBoostStep.factor)
        }

        engagementGeneration += 1
        wantedActive = true
        guard suspensionReasons.isEmpty else {
            setState(.engaging)
            return
        }

        if defaults.bool(forKey: DefaultsKey.recoveryRequired) {
            guard completePendingRecovery() else {
                wantedActive = false
                setState(.unavailable("等待内置显示器恢复标准亮度"))
                return
            }
        }

        guard let screen = DisplayLookup.builtInScreen,
              let displayID = screen.displayBoostID else {
            wantedActive = false
            setState(.unavailable("未找到内置显示器"))
            return
        }
        guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 else {
            wantedActive = false
            setState(.unavailable("内置屏幕不支持 XDR/EDR"))
            return
        }

        let generation = engagementGeneration
        setState(.engaging)

        if let endpoint = GammaTableService.readEndpoint(displayID: displayID),
           endpoint > 1.05 {
            failActivation("检测到其他 Gamma 增亮，请先关闭它")
            return
        }

        activeDisplayID = displayID
        activeColorProfileIdentity = Self.colorProfileIdentity(for: screen)

        if savedNativeBrightness == nil {
            guard let currentBrightness = nativeBrightness.read(displayID: displayID) else {
                failActivation("无法读取系统背光亮度")
                return
            }
            savedNativeBrightness = currentBrightness
            defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            gammaRecoveryHandled = false
            defaults.synchronize()
        }

        guard gamma.captureBaseline(displayID: displayID) else {
            failActivation("无法读取屏幕颜色表")
            return
        }

        guard nativeBrightness.write(1, displayID: displayID) else {
            failActivation("无法设置系统背光亮度")
            return
        }
        backlightPinnedForBoost = true
        guard edrTrigger.start(on: screen) else {
            failActivation("无法创建 EDR 图层")
            return
        }

        waitForEDR(generation: generation, attemptsRemaining: 80)
    }

    @discardableResult
    func disable() -> Bool {
        resumePending = false
        resumeBrightnessBaseline = nil
        wantedActive = false
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        setState(
            restored
                ? .off
                : .unavailable("标准亮度恢复待处理，请保持应用运行")
        )
        return restored
    }

    func setLevel(_ proposed: Float) {
        level = BoostLevel(proposed)
        defaults.set(level.factor, forKey: DefaultsKey.level)

        if wantedActive, state == .active {
            applyCurrentLevel()
        } else {
            publishSnapshot()
        }
    }

    func setLevelFromUserInteraction(_ proposed: Float) {
        let proposedLevel = BoostLevel(proposed)
        if proposedLevel.factor <= BoostLevel.minimum {
            setLevel(proposedLevel.factor)
            if wantedActive {
                endBoostAtNativeMaximum()
            }
            return
        }

        let shouldEnable = !wantedActive
        setLevel(proposedLevel.factor)
        if shouldEnable {
            enable()
        }
    }

    func handleBrightnessKey(
        _ direction: BrightnessKeyDirection,
        fineGrained: Bool
    ) -> Bool {
        if resumePending {
            cancelPendingResume()
            return false
        }
        guard suspensionReasons.isEmpty else { return false }

        if wantedActive {
            if direction == .decrease,
               level.factor <= BoostLevel.minimum {
                endBoostAtNativeMaximum()
                return false
            }

            let next = BrightnessKeyStep.nextBoostLevel(
                from: level.factor,
                direction: direction,
                fineGrained: fineGrained
            )
            if abs(next.factor - level.factor) < 0.0001 {
                return true
            }
            setLevel(next.factor)
            guard wantedActive else { return false }
            if direction == .decrease,
               next.factor <= BoostLevel.minimum {
                endBoostAtNativeMaximum()
            }
            return true
        }

        guard !wantedActive,
              direction == .increase,
              snapshot.potentialEDRHeadroom > 1.05,
              let displayID = DisplayLookup.builtInScreen?.displayBoostID,
              let currentBrightness = nativeBrightness.read(displayID: displayID),
              currentBrightness >= 0.995 else {
            return false
        }

        let next = BrightnessKeyStep.nextBoostLevel(
            from: BoostLevel.minimum,
            direction: .increase,
            fineGrained: fineGrained
        )
        setLevel(next.factor)
        enable()
        return wantedActive
    }

    func brightnessKeyControlDidBecomeUnavailable() {
        guard wantedActive else { return }
        guard let displayID = activeDisplayID ??
                DisplayLookup.builtInScreen?.displayBoostID,
              let currentBrightness = nativeBrightness.read(displayID: displayID) else {
            stopBoostWithoutChangingNativeBrightness("F1/F2 监听已停止，增亮已关闭")
            return
        }
        if currentBrightness < Self.nativeBrightnessMaximumThreshold {
            endBoostPreservingNativeBrightness(currentBrightness)
            return
        }
        disable()
    }

    func displayParametersDidChange() {
        guard wantedActive, suspensionReasons.isEmpty else {
            return
        }

        if resumePending {
            cancelPendingResumeIfBrightnessChanged()
            return
        }

        guard backlightPinnedForBoost,
              let displayID = activeDisplayID else { return }
        disableIfNativeBrightnessChanged(displayID: displayID)
    }

    func suspend(for reason: BoostSuspensionReason) {
        resumePending = false
        let wasUnsuspended = suspensionReasons.isEmpty
        suspensionReasons.insert(reason)
        guard wantedActive, wasUnsuspended else { return }
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        if !restored {
            wantedActive = false
            resumeBrightnessBaseline = nil
        } else if let displayID = DisplayLookup.builtInScreen?.displayBoostID {
            resumeBrightnessBaseline = nativeBrightness.read(displayID: displayID)
        }
        setState(
            restored
                ? .engaging
                : .unavailable("等待内置显示器恢复标准亮度")
        )
    }

    func resume(from reason: BoostSuspensionReason) {
        guard suspensionReasons.remove(reason) != nil,
              suspensionReasons.isEmpty,
              wantedActive else {
            return
        }
        scheduleResume()
    }

    private func scheduleResume() {
        engagementGeneration += 1
        let generation = engagementGeneration
        resumePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self,
                  self.wantedActive,
                  self.suspensionReasons.isEmpty,
                  self.engagementGeneration == generation else { return }
            guard !self.cancelPendingResumeIfBrightnessChanged() else { return }
            self.resumePending = false
            self.resumeBrightnessBaseline = nil
            self.enable()
        }
    }

    func shutdown() {
        resumePending = false
        resumeBrightnessBaseline = nil
        wantedActive = false
        engagementGeneration += 1
        restoreDisplay(restoreNativeBrightness: true)
    }

    func colorSpaceDidChange(on screen: NSScreen) {
        handleColorProfileChange(on: screen, identity: Self.colorProfileIdentity(for: screen))
    }

    func handleColorProfileChange(on screen: NSScreen, identity currentIdentity: ColorProfileIdentity) {
        guard wantedActive,
              let displayID = screen.displayBoostID,
              displayID == activeDisplayID else {
            return
        }

        if let activeColorProfileIdentity,
           activeColorProfileIdentity.matches(currentIdentity) {
            // macOS also emits this notification for transient EDR and display
            // environment refreshes. Keep the boost when the ICC profile itself
            // has not changed.
            return
        }

        let shouldResume = nativeBrightness.read(displayID: displayID).map {
            $0 >= Self.nativeBrightnessMaximumThreshold
        } ?? false
        let originalRestoreBrightness = savedNativeBrightness
        if let currentBrightness = nativeBrightness.read(displayID: displayID) {
            if currentBrightness < Self.nativeBrightnessMaximumThreshold {
                // A color-profile change must use the ColorSync reset below rather than
                // restoring a gamma table captured under the old profile. Preserve a
                // simultaneous native-brightness change by replacing only its restore target.
                savedNativeBrightness = currentBrightness
                defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
                defaults.set(true, forKey: DefaultsKey.recoveryRequired)
                defaults.synchronize()
            }
        } else {
            // A color-profile change must use the ColorSync reset below rather than
            // the ordinary Gamma path. With no trustworthy live brightness, discard the
            // old target before changing display state so this path cannot overwrite it.
            savedNativeBrightness = nil
            defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
        }

        wantedActive = false
        activeColorProfileIdentity = nil
        resumePending = false
        resumeBrightnessBaseline = nil
        backlightPinnedForBoost = false
        engagementGeneration += 1

        GammaTableService.restoreColorSyncDefaults()
        gammaRecoveryHandled = true
        gamma.discardBaseline()
        edrTrigger.stop()

        var nativeBrightnessRestored = true
        if let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
            if nativeBrightnessRestored {
                self.savedNativeBrightness = nil
                defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            }
        }

        defaults.set(
            !nativeBrightnessRestored,
            forKey: DefaultsKey.recoveryRequired
        )
        defaults.synchronize()
        if nativeBrightnessRestored {
            activeDisplayID = nil
            if shouldResume {
                // Rebuild from the NEW ColorSync profile, never reuse the old LUT.
                // Keep the original backlight so a later explicit disable restores it.
                wantedActive = true
                resumeBrightnessBaseline = originalRestoreBrightness
                setState(.engaging)
                if suspensionReasons.isEmpty { scheduleResume() }
            } else {
                setState(.off)
            }
        } else {
            setState(.unavailable("颜色配置已改变；标准亮度恢复待处理"))
        }
    }

    private func waitForEDR(generation: Int, attemptsRemaining: Int) {
        guard generation == engagementGeneration, wantedActive else { return }
        guard let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            failActivation("内置显示器配置已改变")
            return
        }
        guard verifyNativeBrightnessForBoost(displayID: displayID) else { return }

        let currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue
        if currentEDR > 1.05 {
            applyCurrentLevel()
            return
        }

        guard attemptsRemaining > 0 else {
            failActivation("macOS 未能进入 EDR 模式")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForEDR(
                generation: generation,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func applyCurrentLevel() {
        guard wantedActive,
              suspensionReasons.isEmpty,
              let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            return
        }

        guard verifyNativeBrightnessForBoost(displayID: displayID) else { return }
        let safeFactor = targetFactor(for: screen)

        guard gamma.apply(factor: safeFactor) else {
            failActivation("无法应用屏幕增亮")
            return
        }
        setState(.active)
    }

    private func failActivation(_ message: String) {
        resumePending = false
        resumeBrightnessBaseline = nil
        wantedActive = false
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        setState(
            .unavailable(
                restored
                    ? message
                    : "\(message)；标准亮度恢复仍待完成"
            )
        )
    }

    @discardableResult
    private func restoreDisplay(restoreNativeBrightness: Bool) -> Bool {
        backlightPinnedForBoost = false
        let gammaRestored = restoreGammaWithFallback()
        edrTrigger.stop()

        var nativeBrightnessRestored = true
        if restoreNativeBrightness, let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
            if nativeBrightnessRestored {
                self.savedNativeBrightness = nil
                defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            }
        }

        if gammaRestored {
            gamma.discardBaseline()
        }

        let fullyRestored = gammaRestored && nativeBrightnessRestored
        defaults.set(!fullyRestored, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        if fullyRestored {
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }
        return fullyRestored
    }

    private func startIntegrityTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performIntegrityCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        integrityTimer = timer
    }

    private func performIntegrityCheck() {
        guard wantedActive else {
            retryPendingRecovery()
            return
        }
        guard suspensionReasons.isEmpty else { return }
        guard state == .active else {
            publishSnapshot()
            return
        }
        guard let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            failActivation("内置显示器配置已改变")
            return
        }

        guard verifyNativeBrightnessForBoost(displayID: displayID) else { return }

        if screen.maximumExtendedDynamicRangeColorComponentValue <= 1.05 {
            guard restoreGammaBeforeRetrigger() else {
                failActivation("无法安全恢复屏幕颜色表")
                return
            }
            edrTrigger.stop()
            gamma.discardBaseline()
            engagementGeneration += 1
            let generation = engagementGeneration
            guard gamma.captureBaseline(displayID: displayID) else {
                failActivation("无法重新读取屏幕颜色表")
                return
            }
            gammaRecoveryHandled = false
            guard edrTrigger.start(on: screen) else {
                failActivation("无法恢复 EDR 模式")
                return
            }
            setState(.engaging)
            waitForEDR(generation: generation, attemptsRemaining: 80)
            return
        }

        let expectedFactor = targetFactor(for: screen)
        let factorChanged = abs(gamma.appliedFactor - expectedFactor) > 0.015
        if factorChanged || !gamma.appearsApplied() {
            applyCurrentLevel()
        }
        publishSnapshot()
    }

    private func targetFactor(for screen: NSScreen) -> Float {
        let currentEDR = Float(
            screen.maximumExtendedDynamicRangeColorComponentValue
        )
        let calibratedFactor = BoostCalibration.gammaFactor(
            level: level,
            currentEDR: currentEDR
        )
        return min(calibratedFactor, max(1, currentEDR))
    }

    @discardableResult
    private func disableIfNativeBrightnessChanged(
        displayID: CGDirectDisplayID
    ) -> Bool {
        guard let currentBrightness = nativeBrightness.read(displayID: displayID),
              currentBrightness < Self.nativeBrightnessMaximumThreshold else {
            return false
        }

        endBoostPreservingNativeBrightness(currentBrightness)
        return true
    }

    private func verifyNativeBrightnessForBoost(
        displayID: CGDirectDisplayID
    ) -> Bool {
        guard let currentBrightness = nativeBrightness.read(displayID: displayID) else {
            stopBoostWithoutChangingNativeBrightness("无法确认系统背光亮度，增亮已关闭")
            return false
        }
        guard currentBrightness < Self.nativeBrightnessMaximumThreshold else {
            return true
        }
        endBoostPreservingNativeBrightness(currentBrightness)
        return false
    }

    private func endBoostPreservingNativeBrightness(_ currentBrightness: Float) {
        // A brightness key, Control Center, auto-brightness, or the system itself moved
        // the real backlight. Treat that as the newest user/system intent instead of
        // fighting it on the next integrity pass and making the display jump brighter.
        savedNativeBrightness = currentBrightness
        defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
        defaults.set(true, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        disable()
    }

    private func stopBoostWithoutChangingNativeBrightness(_ message: String) {
        resumePending = false
        resumeBrightnessBaseline = nil
        wantedActive = false
        backlightPinnedForBoost = false
        engagementGeneration += 1

        // The live backlight value is unknown, so discard the old restore target before
        // touching Gamma. A crash from this point can recover ColorSync, but can never
        // guess at and overwrite the user's current hardware brightness.
        savedNativeBrightness = nil
        defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
        defaults.set(true, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()

        let gammaRestored = restoreGammaWithFallback()
        edrTrigger.stop()
        if gammaRestored {
            gamma.discardBaseline()
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }

        defaults.set(!gammaRestored, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        setState(
            gammaRestored
                ? .unavailable(message)
                : .unavailable("\(message)；屏幕颜色恢复待处理")
        )
    }

    private func endBoostAtNativeMaximum() {
        endBoostPreservingNativeBrightness(1)
    }

    private func cancelPendingResume() {
        resumePending = false
        resumeBrightnessBaseline = nil
        wantedActive = false
        engagementGeneration += 1
        setState(.off)
    }

    @discardableResult
    private func cancelPendingResumeIfBrightnessChanged() -> Bool {
        guard resumePending else { return false }
        guard let baseline = resumeBrightnessBaseline,
              let displayID = DisplayLookup.builtInScreen?.displayBoostID,
              let current = nativeBrightness.read(displayID: displayID),
              abs(current - baseline) < 0.005 else {
            cancelPendingResume()
            return true
        }
        return false
    }

    private func restoreGammaBeforeRetrigger() -> Bool {
        restoreGammaWithFallback()
    }

    private func restoreGammaWithFallback() -> Bool {
        if gamma.restore() {
            gammaRecoveryHandled = true
            return true
        }

        if !gamma.baselineDisplayIsOnline {
            if let currentDisplayID = DisplayLookup.builtInScreen?.displayBoostID,
               CGDisplayIsOnline(currentDisplayID) != 0,
               gamma.restore(to: currentDisplayID) {
                activeDisplayID = currentDisplayID
                gammaRecoveryHandled = true
                return true
            }
            return false
        }

        if !gammaRecoveryHandled {
            GammaTableService.restoreColorSyncDefaults()
            gammaRecoveryHandled = true
        }
        return gamma.matchesBaseline() || !gamma.baselineDisplayIsOnline
    }

    private func restoreNativeBrightnessValue(_ value: Float) -> Bool {
        if let currentDisplayID = DisplayLookup.builtInScreen?.displayBoostID,
           nativeBrightness.write(value, displayID: currentDisplayID) {
            return true
        }

        if let activeDisplayID,
           CGDisplayIsOnline(activeDisplayID) != 0,
           nativeBrightness.write(value, displayID: activeDisplayID) {
            return true
        }
        return false
    }

    private func completePendingRecovery() -> Bool {
        if gamma.hasBaseline {
            return restoreDisplay(restoreNativeBrightness: true)
        }
        return recoverInterruptedSession()
    }

    private func retryPendingRecovery() {
        guard defaults.bool(forKey: DefaultsKey.recoveryRequired) else { return }
        if completePendingRecovery() {
            if state != .off {
                setState(.off)
            }
        } else if state != .unavailable("等待内置显示器恢复标准亮度") {
            setState(.unavailable("等待内置显示器恢复标准亮度"))
        }
    }

    @discardableResult
    private func recoverInterruptedSession() -> Bool {
        guard DisplayLookup.builtInScreen != nil else { return false }

        if !gammaRecoveryHandled {
            GammaTableService.restoreColorSyncDefaults()
            gammaRecoveryHandled = true
        }

        var nativeBrightnessRestored = true
        if let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
        }

        if nativeBrightnessRestored {
            savedNativeBrightness = nil
            defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(false, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }
        return nativeBrightnessRestored
    }

    private func setState(_ newState: BoostState) {
        if state != newState {
            logger.info("Boost state: \(String(describing: newState), privacy: .public)")
            // Small, persistent breadcrumbs make field failures diagnosable.
            defaults.set(String(describing: newState), forKey: "lastBoostState")
            defaults.set(Date().timeIntervalSince1970, forKey: "lastBoostStateAt")
        }
        state = newState
        publishSnapshot()
    }

    private func publishSnapshot() {
        onSnapshot?(snapshot)
    }

    private static func colorProfileIdentity(
        for screen: NSScreen
    ) -> ColorProfileIdentity {
        ColorProfileIdentity(
            iccProfileData: screen.colorSpace?.iccProfileData,
            fallbackName: screen.colorSpace?.localizedName
        )
    }
}
