import AppKit
import Darwin
import Foundation

private let daemonLabel = "com.georgeolaru.limpet"
private let menuLabel = "com.georgeolaru.limpet.menu"
private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
private let defaultScriptPath = "\(homeDirectory)/.local/bin/limpet.sh"
private let scriptPath = ProcessInfo.processInfo.environment["LIMPET_SCRIPT"] ?? defaultScriptPath
private let configPath = "\(homeDirectory)/.config/limpet/config.sh"
private let defaultLogPath = "\(homeDirectory)/Library/Logs/limpet.log"
private let daemonPlistPath = "\(homeDirectory)/Library/LaunchAgents/\(daemonLabel).plist"
private let uninstallerPath = "\(homeDirectory)/.local/bin/limpet-uninstall.sh"
private let repoURL = "https://github.com/georgeolaru/limpet"

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], stdin: String? = nil) -> CommandResult {
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = outPipe

        var inPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            inPipe = p
            process.standardInput = p
        }

        do {
            try process.run()
            if let stdin, let inPipe {
                let handle = inPipe.fileHandleForWriting
                if let data = stdin.data(using: .utf8) { handle.write(data) }
                handle.write(Data([0x0a]))   // trailing newline for `read`
                handle.closeFile()
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return CommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }
}

// MARK: - Daemon / config helpers (shared by the menu and the settings window)

@discardableResult
private func restartDaemon() -> CommandResult {
    let uid = String(getuid())
    let specifier = "gui/\(uid)/\(daemonLabel)"
    let printResult = Shell.run("/bin/launchctl", ["print", specifier])
    if printResult.exitCode != 0 {
        let bootstrap = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlistPath])
        if bootstrap.exitCode != 0 { return bootstrap }
    }
    return Shell.run("/bin/launchctl", ["kickstart", "-k", specifier])
}

@discardableResult
private func setConfig(_ key: String, _ value: String) -> CommandResult {
    Shell.run(scriptPath, ["--set-config", key, value])
}

private func listSavedNetworks() -> [String] {
    let result = Shell.run(scriptPath, ["--list-saved-networks"])
    guard result.exitCode == 0 else { return [] }
    return result.output
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private struct LimpetSettings {
    var hotspotSSID = ""
    var tryRemembered = true
    var preferWifi = true
    var checkInterval = 45
    var maxInterval = 300
    var passwordSet = false
}

private func loadSettings() -> LimpetSettings {
    var s = LimpetSettings()
    let result = Shell.run(scriptPath, ["--print-config"])
    for rawLine in result.output.split(whereSeparator: \.isNewline) {
        let parts = String(rawLine).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = String(parts[0])
        let value = String(parts[1])
        switch key {
        case "HOTSPOT_SSID": s.hotspotSSID = value
        case "TRY_REMEMBERED_HOTSPOT": s.tryRemembered = (value == "1")
        case "PREFER_WIFI_OVER_HOTSPOT": s.preferWifi = (value == "1")
        case "CHECK_INTERVAL": s.checkInterval = Int(value) ?? 45
        case "MAX_INTERVAL": s.maxInterval = Int(value) ?? 300
        case "HOTSPOT_PASSWORD_SET": s.passwordSet = (value == "1")
        default: break
        }
    }
    return s
}

private func performUninstall() {
    let alert = NSAlert()
    alert.messageText = "Uninstall Limpet?"
    alert.informativeText = "This stops the agents and removes the script, menu app, and LaunchAgents. Your config and logs are kept."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    if FileManager.default.fileExists(atPath: uninstallerPath) {
        // Run detached so it survives this app being torn down by the uninstaller.
        Shell.run("/bin/bash", ["-c", "nohup bash \"\(uninstallerPath)\" >/tmp/limpet-uninstall.log 2>&1 &"])
    } else {
        let uid = String(getuid())
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(daemonLabel)"])
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(menuLabel)"])
    }
    NSApp.terminate(nil)
}

// MARK: - Settings: a CodexBar-style tabbed preferences window

// Shared layout helpers for a single preference pane.
private class SettingsPane: NSViewController {
    let stack = NSStackView()
    var paneWidth: CGFloat { 560 }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        view = root
        build()
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: paneWidth, height: max(root.fittingSize.height, 160))
    }

    func build() {}

    // Add a full-width block to the pane.
    func addRow(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = paneWidth - 48
        return label
    }

    func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        return label
    }

    func hSpacer(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // A checkbox (its own title) with a gray caption indented beneath it.
    func checkboxBlock(_ checkbox: NSButton, _ caption: String) -> NSView {
        checkbox.font = NSFont.systemFont(ofSize: 13)
        let captionRow = NSStackView(views: [hSpacer(20), captionLabel(caption)])
        captionRow.orientation = .horizontal
        captionRow.alignment = .firstBaseline
        let block = NSStackView(views: [checkbox, captionRow])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        return block
    }

    // A title on the left, a control pinned to the right, with a caption beneath.
    func controlBlock(_ title: String, _ control: NSView, _ caption: String) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.addView(titleLabel(title), in: .leading)
        header.addView(control, in: .trailing)
        let block = NSStackView(views: [header, captionLabel(caption)])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        header.trailingAnchor.constraint(equalTo: block.trailingAnchor).isActive = true
        return block
    }

    // Center a view within a full-width row.
    func addCentered(_ inner: NSView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        addRow(container)
    }
}

// MARK: Hotspot pane

private final class HotspotPane: SettingsPane {
    private let hotspotPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordField = NSSecureTextField()
    private let rememberedCheck = NSButton(checkboxWithTitle: "Use saved macOS credentials if no password is set", target: nil, action: nil)
    private let testButton = NSButton(title: "Test hotspot now", target: nil, action: nil)
    private let testResultLabel = NSTextField(wrappingLabelWithString: "")
    private let workQueue = DispatchQueue(label: "limpet-menu.hotspot", qos: .userInitiated)
    private var settings = LimpetSettings()

    override func build() {
        addRow(sectionHeader("Phone hotspot"))

        hotspotPopup.target = self
        hotspotPopup.action = #selector(hotspotChanged)
        hotspotPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        addRow(controlBlock("Hotspot network", hotspotPopup,
                            "Your phone’s hotspot name — on iPhone, Settings ▸ General ▸ About ▸ Name."))

        passwordField.placeholderString = "Hotspot password"
        passwordField.target = self
        passwordField.action = #selector(passwordCommitted)   // fires on Return
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        addRow(controlBlock("Password", passwordField,
                            "Stored in your macOS Keychain, never on disk. Press Return to save."))

        rememberedCheck.target = self
        rememberedCheck.action = #selector(rememberedToggled)
        addRow(checkboxBlock(rememberedCheck,
                             "Falls back to credentials macOS already saved for this network."))

        addRow(divider())

        testButton.target = self
        testButton.action = #selector(testHotspot)
        testButton.bezelStyle = .rounded
        testResultLabel.font = NSFont.systemFont(ofSize: 12)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.preferredMaxLayoutWidth = paneWidth - 48
        let testStack = NSStackView(views: [testButton, testResultLabel])
        testStack.orientation = .vertical
        testStack.alignment = .leading
        testStack.spacing = 6
        addRow(testStack)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        settings = loadSettings()
        var items = listSavedNetworks()
        if !settings.hotspotSSID.isEmpty && !items.contains(settings.hotspotSSID) {
            items.insert(settings.hotspotSSID, at: 0)
        }
        hotspotPopup.removeAllItems()
        if items.isEmpty {
            hotspotPopup.addItem(withTitle: "(no saved networks)")
        } else {
            hotspotPopup.addItems(withTitles: items)
            if !settings.hotspotSSID.isEmpty { hotspotPopup.selectItem(withTitle: settings.hotspotSSID) }
        }
        passwordField.stringValue = ""
        passwordField.placeholderString = settings.passwordSet ? "•••••••• (saved — type to replace)" : "Hotspot password"
        rememberedCheck.state = settings.tryRemembered ? .on : .off
        testResultLabel.stringValue = ""
    }

    @objc private func hotspotChanged() {
        guard let ssid = hotspotPopup.titleOfSelectedItem, ssid != "(no saved networks)" else { return }
        settings.hotspotSSID = ssid
        applyAndRestart { setConfig("HOTSPOT_SSID", ssid) }
        workQueue.async {
            let s = loadSettings()
            DispatchQueue.main.async {
                self.passwordField.placeholderString = s.passwordSet ? "•••••••• (saved — type to replace)" : "Hotspot password"
            }
        }
    }

    @objc private func passwordCommitted() {
        let password = passwordField.stringValue
        let ssid = settings.hotspotSSID
        guard !ssid.isEmpty else {
            testResultLabel.textColor = .systemRed
            testResultLabel.stringValue = "Pick a hotspot network first."
            return
        }
        workQueue.async {
            let result = Shell.run(scriptPath, ["--set-hotspot-password", ssid], stdin: password)
            DispatchQueue.main.async {
                let saved = result.output.contains("saved")
                self.testResultLabel.textColor = saved ? .systemGreen : .secondaryLabelColor
                self.testResultLabel.stringValue = password.isEmpty ? "Password cleared." : (saved ? "Password saved to Keychain." : "Keychain error.")
                self.passwordField.stringValue = ""
                self.passwordField.placeholderString = password.isEmpty ? "Hotspot password" : "•••••••• (saved — type to replace)"
            }
        }
    }

    @objc private func rememberedToggled() {
        let on = rememberedCheck.state == .on
        settings.tryRemembered = on
        applyAndRestart { setConfig("TRY_REMEMBERED_HOTSPOT", on ? "1" : "0") }
    }

    @objc private func testHotspot() {
        testButton.isEnabled = false
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.stringValue = "Testing… turn the phone’s hotspot on and keep it nearby."
        workQueue.async {
            let result = Shell.run(scriptPath, ["--test-hotspot"])
            let reason = Self.testFailureReason(from: result.output)
            DispatchQueue.main.async {
                self.testButton.isEnabled = true
                if result.exitCode == 0 {
                    self.testResultLabel.textColor = .systemGreen
                    self.testResultLabel.stringValue = "✓ Internet OK via hotspot."
                } else {
                    self.testResultLabel.textColor = .systemRed
                    self.testResultLabel.stringValue = "✗ \(reason)"
                }
            }
        }
    }

    private static func testFailureReason(from output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("no hotspot configured") { return "Pick your hotspot network first." }
        if lower.contains("no wi-fi interface") { return "No Wi-Fi interface found." }
        if lower.contains("could not find network") || lower.contains("not in range") {
            return "Hotspot not found — turn the phone’s hotspot ON and keep it nearby and awake."
        }
        if lower.contains("captive") { return "That network needs a login (captive portal)." }
        if lower.contains("no internet") { return "Joined the hotspot, but it has no internet — check the phone’s data." }
        return "Test failed — check the hotspot is on and the password is correct."
    }

    private func applyAndRestart(_ work: @escaping () -> CommandResult) {
        workQueue.async {
            _ = work()
            _ = restartDaemon()
        }
    }
}

// MARK: Behavior pane

private final class BehaviorPane: SettingsPane {
    private let preferWifiCheck = NSButton(checkboxWithTitle: "Automatically return to Wi-Fi when available", target: nil, action: nil)
    private let checkIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maxIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let workQueue = DispatchQueue(label: "limpet-menu.behavior", qos: .userInitiated)
    private var settings = LimpetSettings()
    private let checkPresets = [15, 30, 45, 60, 90, 120]
    private let backoffPresets = [120, 180, 300, 600, 900]

    override func build() {
        addRow(sectionHeader("Wi-Fi"))
        preferWifiCheck.target = self
        preferWifiCheck.action = #selector(preferWifiToggled)
        addRow(checkboxBlock(preferWifiCheck,
                             "When known Wi-Fi returns, move off the hotspot back onto it."))

        addRow(divider())
        addRow(sectionHeader("Timing"))

        checkIntervalPopup.target = self
        checkIntervalPopup.action = #selector(checkIntervalChanged)
        checkIntervalPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true
        addRow(controlBlock("Check interval while online", checkIntervalPopup,
                            "How often Limpet verifies the connection when everything’s fine."))

        maxIntervalPopup.target = self
        maxIntervalPopup.action = #selector(maxIntervalChanged)
        maxIntervalPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true
        addRow(controlBlock("Max backoff when offline", maxIntervalPopup,
                            "Longest wait between retries while it can’t get online."))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        settings = loadSettings()
        preferWifiCheck.state = settings.preferWifi ? .on : .off
        fill(checkIntervalPopup, presets: checkPresets, current: settings.checkInterval)
        fill(maxIntervalPopup, presets: backoffPresets, current: settings.maxInterval)
    }

    private func fill(_ popup: NSPopUpButton, presets: [Int], current: Int) {
        var values = presets
        if !values.contains(current) { values.append(current); values.sort() }
        popup.removeAllItems()
        popup.addItems(withTitles: values.map { "\($0) s" })
        popup.selectItem(withTitle: "\(current) s")
    }

    private func seconds(_ popup: NSPopUpButton) -> Int? {
        guard let title = popup.titleOfSelectedItem else { return nil }
        return Int(title.replacingOccurrences(of: " s", with: ""))
    }

    @objc private func preferWifiToggled() {
        let on = preferWifiCheck.state == .on
        settings.preferWifi = on
        apply { setConfig("PREFER_WIFI_OVER_HOTSPOT", on ? "1" : "0") }
    }

    @objc private func checkIntervalChanged() {
        guard let value = seconds(checkIntervalPopup) else { return }
        settings.checkInterval = value
        apply { setConfig("CHECK_INTERVAL", String(value)) }
    }

    @objc private func maxIntervalChanged() {
        guard let value = seconds(maxIntervalPopup) else { return }
        settings.maxInterval = value
        apply { setConfig("MAX_INTERVAL", String(value)) }
    }

    private func apply(_ work: @escaping () -> CommandResult) {
        workQueue.async {
            _ = work()
            _ = restartDaemon()
        }
    }
}

// MARK: About pane

private final class AboutPane: SettingsPane {
    override func build() {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            icon.image = image
        }
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let name = NSTextField(labelWithString: "Limpet")
        name.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [icon, name, versionLabel])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        addCentered(header)

        let tagline = captionLabel("Keeps your Mac online by failing over to your phone’s hotspot when Wi-Fi drops, then returning to Wi-Fi automatically.")
        tagline.alignment = .center
        addRow(tagline)

        addRow(divider())

        let github = linkButton("View on GitHub", #selector(openGitHub))
        let log = linkButton("Open Log", #selector(openLog))
        let links = NSStackView(views: [github, log])
        links.orientation = .horizontal
        links.spacing = 18
        addRow(links)

        let uninstallButton = NSButton(title: "Uninstall Limpet…", target: self, action: #selector(uninstall))
        uninstallButton.bezelStyle = .rounded
        addRow(uninstallButton)
    }

    private func linkButton(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = NSFont.systemFont(ofSize: 13)
        return button
    }

    @objc private func openGitHub() {
        if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: defaultLogPath))
    }

    @objc private func uninstall() {
        performUninstall()
    }
}

// MARK: Window controller

private final class SettingsWindowController: NSWindowController {
    private let tabController = NSTabViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        self.init(window: window)

        tabController.tabStyle = .toolbar
        addTab(HotspotPane(), label: "Hotspot", symbol: "personalhotspot")
        addTab(BehaviorPane(), label: "Behavior", symbol: "slider.horizontal.3")
        addTab(AboutPane(), label: "About", symbol: "info.circle")
        window.contentViewController = tabController
    }

    private func addTab(_ controller: NSViewController, label: String, symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabController.addTabViewItem(item)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible { window.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Status model

private struct GuardianStatus {
    let internet: String
    let interface: String
    let ipAddress: String
    let defaultRoute: String
    let configFile: String
    let logFile: String
    let agentState: String
    let rawStatus: String
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let workQueue = DispatchQueue(label: "limpet-menu.worker", qos: .utility)
    private var timer: Timer?
    private var currentStatus: GuardianStatus?
    private var refreshInFlight = false
    private var lastActionMessage = ""
    private var appIcon: NSImage?
    private var menuBarIcons: [String: NSImage] = [:]
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appIcon = loadApplicationIcon()
        menuBarIcons = loadMenuBarIcons()
        installApplicationIcon()
        menu.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = menuBarIcons.isEmpty ? "L" : ""
            button.image = menuBarIcon(for: nil)
            button.toolTip = "Limpet"
        }
        statusItem.menu = menu

        rebuildMenu()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func loadApplicationIcon() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return nil
        }
        return icon
    }

    private func loadMenuBarIcons() -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        let resources = [
            "ok": "MenuBarIconTemplateOK",
            "down": "MenuBarIconTemplateDown",
            "captive": "MenuBarIconTemplateCaptive",
            "unknown": "MenuBarIconTemplateUnknown"
        ]

        for (state, resourceName) in resources {
            if let icon = loadMenuBarIcon(named: resourceName) {
                icons[state] = icon
            }
        }

        if icons["ok"] == nil, let fallbackIcon = loadMenuBarIcon(named: "MenuBarIconTemplate") {
            icons["ok"] = fallbackIcon
        }

        return icons
    }

    private func loadMenuBarIcon(named resourceName: String) -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else {
            return nil
        }
        let image = icon.copy() as? NSImage ?? icon
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func menuBarIcon(for status: GuardianStatus?) -> NSImage? {
        let state = status.map { menuBarIconState(for: $0.internet) } ?? "unknown"
        return menuBarIcons[state] ?? menuBarIcons["ok"] ?? menuBarIcons["unknown"]
    }

    private func menuBarIconState(for internetStatus: String) -> String {
        let status = internetStatus.uppercased()
        if status.contains("OK") {
            return "ok"
        }
        if status.contains("CAPTIVE") || status.contains("LOGIN") {
            return "captive"
        }
        if status.contains("DOWN") || status.contains("UNAVAILABLE") {
            return "down"
        }
        return "unknown"
    }

    private func installApplicationIcon() {
        guard let icon = appIcon else { return }
        NSApp.applicationIconImage = icon
    }

    private func refreshStatus(completionMessage: String? = nil) {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        workQueue.async { [weak self] in
            guard let self else { return }
            let status = self.collectStatus()
            DispatchQueue.main.async {
                self.currentStatus = status
                self.refreshInFlight = false
                if let completionMessage {
                    self.lastActionMessage = completionMessage
                }
                self.updateStatusButton(status)
                self.rebuildMenu()
            }
        }
    }

    private func collectStatus() -> GuardianStatus {
        let statusResult = Shell.run(scriptPath, ["--status"])
        let fields = parseStatusFields(statusResult.output)
        let logFile = fields["Log file"] ?? defaultLogPath
        let agent = launchAgentStatus()

        return GuardianStatus(
            internet: fields["Internet"] ?? (statusResult.exitCode == 0 ? "Unknown" : "Unavailable"),
            interface: fields["Wi-Fi interface"] ?? "<unknown>",
            ipAddress: fields["IP address"] ?? "<unknown>",
            defaultRoute: fields["Default route"] ?? "<unknown>",
            configFile: fields["Config file"] ?? configPath,
            logFile: logFile,
            agentState: agent.state,
            rawStatus: statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseStatusFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    private func launchAgentStatus() -> (state: String, pid: String) {
        let specifier = "gui/\(getuid())/\(daemonLabel)"
        let result = Shell.run("/bin/launchctl", ["print", specifier])
        guard result.exitCode == 0 else { return ("stopped", "-") }

        var state = "loaded"
        var pid = "-"
        for rawLine in result.output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = ") {
                state = line.replacingOccurrences(of: "state = ", with: "")
            } else if line.hasPrefix("pid = ") {
                pid = line.replacingOccurrences(of: "pid = ", with: "")
            }
        }
        return (state, pid)
    }

    private func updateStatusButton(_ status: GuardianStatus) {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = menuBarIcons.isEmpty ? "L" : ""
        button.image = menuBarIcon(for: status)
        button.toolTip = "Limpet: \(status.internet)"
    }

    private var isPaused: Bool { currentStatus?.agentState == "stopped" }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status = currentStatus
        menu.addItem(statusHeaderItem(status))

        if !lastActionMessage.isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(disabledItem(shorten(lastActionMessage, limit: 96)))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem(isPaused ? "Resume Limpet" : "Pause Limpet", #selector(togglePause(_:))))
        menu.addItem(actionItem("Check Internet Now", #selector(checkInternetNow(_:))))
        menu.addItem(actionItem("Prefer Wi-Fi Now", #selector(preferWifiNow(_:))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Settings…", #selector(openSettings(_:))))
        menu.addItem(actionItem("Open Log", #selector(openLog(_:))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit Limpet", #selector(quitMenu(_:))))
    }

    private func statusHeaderItem(_ status: GuardianStatus?) -> NSMenuItem {
        let internet = status?.internet ?? "Checking…"
        let up = internet.uppercased()
        let color: NSColor
        if up.contains("OK") { color = .systemGreen }
        else if up.contains("CAPTIVE") { color = .systemOrange }
        else if up.contains("DOWN") || up.contains("UNAVAIL") { color = .systemRed }
        else { color = .systemGray }

        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        title.append(NSAttributedString(string: "Limpet — \(internet)", attributes: [.foregroundColor: NSColor.labelColor]))

        let item = NSMenuItem(title: "Limpet — \(internet)", action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func performMenuAction(_ title: String, _ action: @escaping () -> CommandResult) {
        lastActionMessage = "\(title): running..."
        rebuildMenu()

        workQueue.async { [weak self] in
            let result = action()
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = output.isEmpty ? "exit \(result.exitCode)" : output
            DispatchQueue.main.async {
                self?.lastActionMessage = "\(title): \(shorten(summary, limit: 120))"
                self?.refreshStatus()
            }
        }
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        if isPaused {
            performMenuAction("Resume Limpet") {
                let uid = String(getuid())
                let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlistPath])
                Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(daemonLabel)"])
                return result
            }
        } else {
            performMenuAction("Pause Limpet") {
                Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(daemonLabel)"])
            }
        }
    }

    @objc private func checkInternetNow(_ sender: NSMenuItem) {
        performMenuAction("Check Internet Now") {
            Shell.run(scriptPath, ["--check"])
        }
    }

    @objc private func preferWifiNow(_ sender: NSMenuItem) {
        performMenuAction("Prefer Wi-Fi Now") {
            Shell.run(scriptPath, ["--prefer-wifi-now"])
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.show()
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        let path = currentStatus?.logFile ?? defaultLogPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func quitMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
    }
}

private func shorten(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: max(0, limit - 3))
    return String(text[..<end]) + "..."
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
