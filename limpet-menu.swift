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

// MARK: - Settings window

private final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let hotspotPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordField = NSSecureTextField()
    private let rememberedCheck = NSButton(checkboxWithTitle: "Use saved macOS credentials if no password is set", target: nil, action: nil)
    private let preferWifiCheck = NSButton(checkboxWithTitle: "Automatically return to Wi-Fi when available", target: nil, action: nil)
    private let checkIntervalField = NSTextField()
    private let maxIntervalField = NSTextField()
    private let testButton = NSButton(title: "Test hotspot now", target: nil, action: nil)
    private let testResultLabel = NSTextField(labelWithString: "")
    private let workQueue = DispatchQueue(label: "limpet-menu.settings", qos: .userInitiated)
    private var settings = LimpetSettings()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Limpet — Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(sectionHeader("PHONE HOTSPOT"))
        stack.addArrangedSubview(caption("The fallback network when Wi-Fi has no internet."))

        hotspotPopup.target = self
        hotspotPopup.action = #selector(hotspotChanged)
        hotspotPopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(labeledRow("Hotspot network:", hotspotPopup))

        passwordField.placeholderString = "Hotspot password"
        passwordField.target = self
        passwordField.action = #selector(passwordCommitted)   // fires on Return only
        passwordField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(labeledRow("Password:", passwordField))
        stack.addArrangedSubview(caption("Stored in your macOS Keychain, never written to disk. Press Return to save."))

        rememberedCheck.target = self
        rememberedCheck.action = #selector(rememberedToggled)
        stack.addArrangedSubview(rememberedCheck)

        testButton.target = self
        testButton.action = #selector(testHotspot)
        testButton.bezelStyle = .rounded
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.lineBreakMode = .byTruncatingTail
        let testRow = NSStackView(views: [testButton, testResultLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 10
        stack.addArrangedSubview(testRow)

        stack.addArrangedSubview(spacer(6))
        stack.addArrangedSubview(sectionHeader("BEHAVIOR"))

        preferWifiCheck.target = self
        preferWifiCheck.action = #selector(preferWifiToggled)
        stack.addArrangedSubview(preferWifiCheck)

        checkIntervalField.delegate = self
        checkIntervalField.target = self
        checkIntervalField.action = #selector(intervalsCommitted)
        checkIntervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        stack.addArrangedSubview(labeledRow("Check interval while online (s):", checkIntervalField))

        maxIntervalField.delegate = self
        maxIntervalField.target = self
        maxIntervalField.action = #selector(intervalsCommitted)
        maxIntervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        stack.addArrangedSubview(labeledRow("Max backoff when offline (s):", maxIntervalField))

        stack.addArrangedSubview(caption("Changes apply immediately and restart the background agent."))
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
            if !settings.hotspotSSID.isEmpty {
                hotspotPopup.selectItem(withTitle: settings.hotspotSSID)
            }
        }

        passwordField.stringValue = ""
        passwordField.placeholderString = settings.passwordSet ? "•••••••• (saved — type to replace)" : "Hotspot password"
        rememberedCheck.state = settings.tryRemembered ? .on : .off
        preferWifiCheck.state = settings.preferWifi ? .on : .off
        checkIntervalField.stringValue = String(settings.checkInterval)
        maxIntervalField.stringValue = String(settings.maxInterval)
        testResultLabel.stringValue = ""
    }

    // MARK: control actions

    @objc private func hotspotChanged() {
        guard let ssid = hotspotPopup.titleOfSelectedItem, ssid != "(no saved networks)" else { return }
        settings.hotspotSSID = ssid
        applyAndRestart { setConfig("HOTSPOT_SSID", ssid) }
        // The Keychain password is keyed to the SSID — reflect whether one exists for this one.
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

    @objc private func preferWifiToggled() {
        let on = preferWifiCheck.state == .on
        settings.preferWifi = on
        applyAndRestart { setConfig("PREFER_WIFI_OVER_HOTSPOT", on ? "1" : "0") }
    }

    @objc private func intervalsCommitted() { applyIntervals() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === checkIntervalField || field === maxIntervalField { applyIntervals() }
    }

    private func applyIntervals() {
        let check = max(5, Int(checkIntervalField.stringValue) ?? settings.checkInterval)
        let backoff = max(check, Int(maxIntervalField.stringValue) ?? settings.maxInterval)
        checkIntervalField.stringValue = String(check)
        maxIntervalField.stringValue = String(backoff)
        if check != settings.checkInterval {
            settings.checkInterval = check
            applyAndRestart { setConfig("CHECK_INTERVAL", String(check)) }
        }
        if backoff != settings.maxInterval {
            settings.maxInterval = backoff
            applyAndRestart { setConfig("MAX_INTERVAL", String(backoff)) }
        }
    }

    @objc private func testHotspot() {
        testButton.isEnabled = false
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.stringValue = "Testing… turn on Personal Hotspot."
        workQueue.async {
            let result = Shell.run(scriptPath, ["--test-hotspot"])
            DispatchQueue.main.async {
                self.testButton.isEnabled = true
                let ok = result.exitCode == 0
                self.testResultLabel.textColor = ok ? .systemGreen : .systemRed
                self.testResultLabel.stringValue = ok ? "✓ Internet OK via hotspot." : "✗ Hotspot test failed."
            }
        }
    }

    private func applyAndRestart(_ work: @escaping () -> CommandResult) {
        workQueue.async {
            _ = work()
            _ = restartDaemon()
        }
    }

    // MARK: small view builders

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func caption(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

// MARK: - Status model

private struct GuardianStatus {
    let internet: String
    let interface: String
    let wifiPower: String
    let ipAddress: String
    let defaultRoute: String
    let ssid: String
    let configFile: String
    let logFile: String
    let agentState: String
    let agentPid: String
    let lastLogLine: String
    let rawStatus: String
    let checkedAt: Date
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
            wifiPower: fields["Wi-Fi power"] ?? "<unknown>",
            ipAddress: fields["IP address"] ?? "<unknown>",
            defaultRoute: fields["Default route"] ?? "<unknown>",
            ssid: fields["SSID (best eff.)"] ?? "<unknown>",
            configFile: fields["Config file"] ?? configPath,
            logFile: logFile,
            agentState: agent.state,
            agentPid: agent.pid,
            lastLogLine: lastLine(in: logFile),
            rawStatus: statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines),
            checkedAt: Date()
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

    private func lastLine(in path: String) -> String {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "No log yet."
        }
        return contents.split(whereSeparator: \.isNewline).last.map(String.init) ?? "No log yet."
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
        menu.addItem(disabledItem("Agent: \(status?.agentState ?? "checking") \(pidSuffix(status?.agentPid))"))
        menu.addItem(disabledItem("Wi-Fi: \(status?.interface ?? "-") / \(status?.wifiPower ?? "-")"))
        menu.addItem(disabledItem("SSID: \(status?.ssid ?? "-")"))

        if let status {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(disabledItem("Last log: \(shorten(status.lastLogLine, limit: 96))"))
            menu.addItem(disabledItem("Checked: \(timeString(status.checkedAt))"))
        }

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
        menu.addItem(actionItem("Show Details", #selector(showDetails(_:))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit Limpet", #selector(quitMenu(_:))))
        menu.addItem(actionItem("Uninstall Limpet…", #selector(uninstall(_:))))
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

    private func pidSuffix(_ pid: String?) -> String {
        guard let pid, pid != "-" else { return "" }
        return "(pid \(pid))"
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

    private func performAction(_ title: String, _ action: @escaping () -> CommandResult) {
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
            performAction("Resume Limpet") {
                let uid = String(getuid())
                let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlistPath])
                Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(daemonLabel)"])
                return result
            }
        } else {
            performAction("Pause Limpet") {
                Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(daemonLabel)"])
            }
        }
    }

    @objc private func checkInternetNow(_ sender: NSMenuItem) {
        performAction("Check Internet Now") {
            Shell.run(scriptPath, ["--check"])
        }
    }

    @objc private func preferWifiNow(_ sender: NSMenuItem) {
        performAction("Prefer Wi-Fi Now") {
            Shell.run(scriptPath, ["--prefer-wifi-now"])
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.show()
    }

    @objc private func showDetails(_ sender: NSMenuItem) {
        let status = currentStatus
        let alert = NSAlert()
        alert.messageText = "Limpet"
        alert.informativeText = [
            status?.rawStatus ?? "Status unavailable.",
            "",
            "Agent: \(status?.agentState ?? "unknown") \(pidSuffix(status?.agentPid))",
            "Last log: \(status?.lastLogLine ?? "No log yet.")"
        ].joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        let path = currentStatus?.logFile ?? defaultLogPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func uninstall(_ sender: NSMenuItem) {
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

private func timeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
