import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let boostController: BoostController
    private let brightnessKeyService: BrightnessKeyService
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let toggleItem = NSMenuItem()
    private let statusTextItem = NSMenuItem()
    private let brightnessKeysItem = NSMenuItem()
    private let percentageLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()

    init(
        boostController: BoostController,
        brightnessKeyService: BrightnessKeyService
    ) {
        self.boostController = boostController
        self.brightnessKeyService = brightnessKeyService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configureMenu()

        boostController.onSnapshot = { [weak self] snapshot in
            self?.render(snapshot)
        }
        render(boostController.snapshot)
    }

    func menuWillOpen(_ menu: NSMenu) {
        brightnessKeyService.start()
        render(boostController.snapshot)
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "sun.max.circle",
            accessibilityDescription: "Display Boost"
        )
        statusItem.button?.toolTip = "Display Boost"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        let titleItem = NSMenuItem(title: "Display Boost", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        statusTextItem.isEnabled = false
        menu.addItem(statusTextItem)
        menu.addItem(.separator())

        toggleItem.target = self
        toggleItem.action = #selector(toggleBoost)
        menu.addItem(toggleItem)

        menu.addItem(makeSliderItem())

        let restoreItem = NSMenuItem(
            title: "恢复标准亮度",
            action: #selector(restoreStandardBrightness),
            keyEquivalent: "r"
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        brightnessKeysItem.target = self
        brightnessKeysItem.action = #selector(requestBrightnessKeyAccess)
        menu.addItem(brightnessKeysItem)

        menu.addItem(.separator())

        let peakInfo = NSMenuItem(
            title: "1600 nit 仅为局部峰值",
            action: nil,
            keyEquivalent: ""
        )
        peakInfo.isEnabled = false
        menu.addItem(peakInfo)

        let backlightInfo = NSMenuItem(
            title: "开启时会临时拉满系统背光",
            action: nil,
            keyEquivalent: ""
        )
        backlightInfo.isEnabled = false
        menu.addItem(backlightInfo)

        let conflictInfo = NSMenuItem(
            title: "请勿与其他 Gamma 增亮工具同时使用",
            action: nil,
            keyEquivalent: ""
        )
        conflictInfo.isEnabled = false
        menu.addItem(conflictInfo)

        let quitItem = NSMenuItem(
            title: "退出 Display Boost",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 62))

        let caption = NSTextField(labelWithString: "增亮目标（100–160%）")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.frame = NSRect(x: 14, y: 38, width: 140, height: 17)
        container.addSubview(caption)

        percentageLabel.alignment = .right
        percentageLabel.textColor = .secondaryLabelColor
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentageLabel.frame = NSRect(x: 190, y: 38, width: 66, height: 17)
        container.addSubview(percentageLabel)

        slider.minValue = Double(BoostLevel.minimum)
        slider.maxValue = Double(BoostLevel.maximum)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.frame = NSRect(x: 12, y: 8, width: 246, height: 24)
        slider.setAccessibilityLabel("增亮强度")
        container.addSubview(slider)

        item.view = container
        return item
    }

    private func render(_ snapshot: BoostSnapshot) {
        slider.doubleValue = snapshot.level.normalizedSliderValue
        percentageLabel.stringValue = "\(snapshot.level.percentage)%"

        let active = snapshot.state.isRunning
        toggleItem.state = active ? .on : .off
        toggleItem.title = active ? "关闭增亮" : "开启增亮"

        let symbol: String
        switch snapshot.state {
        case .off:
            symbol = "sun.max.circle"
            statusTextItem.title = "状态：标准亮度 · 点“开启增亮”或拖动滑杆"
        case .engaging:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = "状态：正在启用 EDR…"
        case .active:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = String(
                format: "状态：已增亮 · EDR %.2fx",
                snapshot.currentEDRHeadroom
            )
        case let .unavailable(message):
            symbol = "exclamationmark.triangle"
            statusTextItem.title = "状态：\(message)"
        }

        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Display Boost"
        )
        refreshBrightnessKeyStatus()
    }

    func refreshBrightnessKeyStatus() {
        if !brightnessKeyService.isTrusted {
            brightnessKeysItem.title = "F1/F2 未接管：点此授予“辅助功能”权限…"
            brightnessKeysItem.state = .off
        } else if brightnessKeyService.isRunning {
            brightnessKeysItem.title = "F1/F2：最高 160%（已启用）"
            brightnessKeysItem.state = .on
        } else {
            brightnessKeysItem.title = "F1/F2：监听未启动，点此重试…"
            brightnessKeysItem.state = .off
        }
    }

    @objc private func toggleBoost() {
        boostController.toggle()
    }

    @objc private func sliderChanged() {
        boostController.setLevelFromUserInteraction(Float(slider.doubleValue))
    }

    @objc private func restoreStandardBrightness() {
        boostController.disable()
    }

    @objc private func requestBrightnessKeyAccess() {
        if !brightnessKeyService.isTrusted {
            BrightnessKeyService.requestAccessibilityPermission()
            if let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(settingsURL)
            }
        }
        brightnessKeyService.start()
        refreshBrightnessKeyStatus()
    }

    @objc private func quit() {
        boostController.shutdown()
        NSApp.terminate(nil)
    }
}
