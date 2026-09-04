import AppKit
import Darwin

@main
enum DisplayBoostApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared

        if CommandLine.arguments.contains("--hardware-self-test") {
            runHardwareSelfTest(application: application)
            return
        }

        let delegate = AppDelegate()

        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    @MainActor
    private static func runHardwareSelfTest(application: NSApplication) {
        application.setActivationPolicy(.accessory)

        guard let instanceLock = InstanceLock.acquire() else {
            fputs("SELFTEST FAIL: Display Boost is already running\n", stderr)
            Darwin.exit(2)
        }

        let controller = BoostController()
        let brightnessService = NativeBrightnessService()
        guard let displayID = DisplayLookup.builtInScreen?.displayBoostID,
              let baselineEndpoint = GammaTableService.readEndpoint(
                displayID: displayID
              ),
              let baselineBrightness = brightnessService.read(displayID: displayID) else {
            fputs("SELFTEST FAIL: unable to read built-in display state\n", stderr)
            Darwin.exit(2)
        }

        let previousLevel = controller.level.factor
        let requestedTestLevel = Float(
            ProcessInfo.processInfo.environment["DISPLAYBOOST_SELF_TEST_LEVEL"] ?? ""
        ) ?? 1.05
        var completionStarted = false

        controller.onSnapshot = { snapshot in
            print(
                "SELFTEST state=\(snapshot.state) " +
                "currentEDR=\(snapshot.currentEDRHeadroom) " +
                "potentialEDR=\(snapshot.potentialEDRHeadroom)"
            )

            guard snapshot.state == .active, !completionStarted else { return }
            completionStarted = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let activeEndpoint = GammaTableService.readEndpoint(
                    displayID: displayID
                )
                let activeBrightness = brightnessService.read(displayID: displayID)
                let controllerReportedRestore = controller.disable()
                let restoredEndpoint = GammaTableService.readEndpoint(
                    displayID: displayID
                )
                let restoredBrightness = brightnessService.read(displayID: displayID)
                controller.setLevel(previousLevel)

                let boostWasApplied = activeEndpoint.map {
                    $0 > baselineEndpoint + 0.01
                } ?? false
                let baselineWasRestored = restoredEndpoint.map {
                    abs($0 - baselineEndpoint) < 0.025
                } ?? false
                let backlightWasRaised = activeBrightness.map { $0 >= 0.99 } ?? false
                let backlightWasRestored = restoredBrightness.map {
                    abs($0 - baselineBrightness) < 0.01
                } ?? false

                if boostWasApplied && baselineWasRestored &&
                    backlightWasRaised && backlightWasRestored &&
                    controllerReportedRestore {
                    print(
                        "SELFTEST PASS: gamma \(baselineEndpoint) -> " +
                        "\(activeEndpoint!) -> \(restoredEndpoint!); " +
                        "backlight \(baselineBrightness) -> " +
                        "\(activeBrightness!) -> \(restoredBrightness!)"
                    )
                    application.terminate(nil)
                } else {
                    fputs(
                        "SELFTEST FAIL: display readback did not verify apply/restore\n",
                        stderr
                    )
                    Darwin.exit(2)
                }
            }
        }

        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                controller.shutdown()
                application.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }

        print("SELFTEST requestedLevel=\(BoostLevel(requestedTestLevel).factor)")
        controller.setLevel(requestedTestLevel)
        controller.enable()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !completionStarted else { return }
            controller.shutdown()
            controller.setLevel(previousLevel)
            fputs("SELFTEST FAIL: boost did not become active\n", stderr)
            Darwin.exit(2)
        }

        withExtendedLifetime((instanceLock, signalSources)) {
            application.run()
        }
    }
}
