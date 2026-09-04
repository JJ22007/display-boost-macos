import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let brightnessKeysPromptedBuild = "brightnessKeysPromptedBuild"
    }

    private var instanceLock: InstanceLock?
    private var boostController: BoostController?
    private var brightnessKeyService: BrightnessKeyService?
    private var statusController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []
    private var brightnessKeyHealthTimer: Timer?
    private var brightnessKeysWereRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let instanceLock = InstanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock

        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.accessory)

        let boostController = BoostController()
        self.boostController = boostController

        let brightnessKeyService = BrightnessKeyService {
            [weak boostController] direction, fineGrained in
            boostController?.handleBrightnessKey(
                direction,
                fineGrained: fineGrained
            ) ?? false
        }
        self.brightnessKeyService = brightnessKeyService
        statusController = StatusItemController(
            boostController: boostController,
            brightnessKeyService: brightnessKeyService
        )

        installLifecycleObservers()
        installSignalHandlers()
        configureBrightnessKeys()

        if CommandLine.arguments.contains("--auto-enable-for-test") {
            let requestedLevel = Float(
                ProcessInfo.processInfo.environment["DISPLAYBOOST_TEST_LEVEL"] ?? ""
            ) ?? 1.25
            boostController.setLevel(requestedLevel)
            boostController.enable()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightnessKeyService?.stop()
        boostController?.shutdown()
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenColorSpaceDidChange),
            name: NSScreen.colorSpaceDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(screenWillSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(screenDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.brightnessKeyService?.stop()
                self?.boostController?.shutdown()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func systemWillSleep() {
        boostController?.suspend(for: .systemSleep)
    }

    @objc private func systemDidWake() {
        boostController?.resume(from: .systemSleep)
    }

    @objc private func screenWillSleep() {
        boostController?.suspend(for: .screenSleep)
    }

    @objc private func screenDidWake() {
        boostController?.resume(from: .screenSleep)
    }

    @objc private func sessionDidResignActive() {
        boostController?.suspend(for: .inactiveSession)
    }

    @objc private func sessionDidBecomeActive() {
        boostController?.resume(from: .inactiveSession)
    }

    @objc private func screenColorSpaceDidChange(_ notification: Notification) {
        guard let screen = notification.object as? NSScreen else { return }
        boostController?.colorSpaceDidChange(on: screen)
    }

    @objc private func displayParametersDidChange() {
        boostController?.displayParametersDidChange()
    }

    private func configureBrightnessKeys() {
        guard let brightnessKeyService else { return }
        let started = brightnessKeyService.start()

        let skipPrompt = ProcessInfo.processInfo.environment[
            "DISPLAYBOOST_SKIP_ACCESSIBILITY_PROMPT"
        ] == "1"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unbundled"
        if !started,
           !skipPrompt,
           UserDefaults.standard.string(
            forKey: DefaultsKey.brightnessKeysPromptedBuild
           ) != currentBuild {
            UserDefaults.standard.set(
                currentBuild,
                forKey: DefaultsKey.brightnessKeysPromptedBuild
            )
            UserDefaults.standard.synchronize()
            BrightnessKeyService.requestAccessibilityPermission()
        }

        brightnessKeysWereRunning = started
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkBrightnessKeyHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        brightnessKeyHealthTimer = timer
    }

    private func checkBrightnessKeyHealth() {
        guard let brightnessKeyService else { return }
        let runningNow = brightnessKeyService.start()
        if brightnessKeysWereRunning && !runningNow {
            boostController?.brightnessKeyControlDidBecomeUnavailable()
        }
        brightnessKeysWereRunning = runningNow
        statusController?.refreshBrightnessKeyStatus()
    }
}
