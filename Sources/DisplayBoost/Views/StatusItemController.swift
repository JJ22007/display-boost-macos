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
        menu.autoenablesItems = false

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

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 62))

        let caption = NSTextField(labelWithString: "亮度")
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
        let supported = snapshot.potentialEDRHeadroom > 1.05
        toggleItem.isEnabled = active || supported
        slider.isEnabled = supported
        statusTextItem.toolTip = nil

        let symbol: String
        switch snapshot.state {
        case .off:
            symbol = "sun.max.circle"
            statusTextItem.title = supported ? "标准亮度" : "此屏幕不支持增亮"
        case .engaging:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = "正在恢复…"
        case .active:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = "增亮已开启"
        case let .unavailable(message):
            symbol = "exclamationmark.triangle"
            statusTextItem.title = "暂不可用 · 点击开启重试"
            statusTextItem.toolTip = message
        }

        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Display Boost"
        )
        refreshBrightnessKeyStatus()
    }

    func refreshBrightnessKeyStatus() {
        if !brightnessKeyService.isTrusted {
            brightnessKeysItem.title = "授权 F1 / F2…"
            brightnessKeysItem.state = .off
        } else if brightnessKeyService.isRunning {
            brightnessKeysItem.title = "F1 / F2"
            brightnessKeysItem.state = .on
        } else {
            brightnessKeysItem.title = "重试 F1 / F2"
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
