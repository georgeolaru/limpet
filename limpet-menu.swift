import AppKit
import Darwin
import Foundation
import WebKit

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

/// The gateway of the network this Mac is on right now (the runtime label key).
private func currentGateway() -> String {
    let result = Shell.run("/sbin/route", ["-n", "get", "default"])
    for line in result.output.split(whereSeparator: \.isNewline) {
        let s = String(line).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("gateway:") {
            return s.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

private struct LimpetSettings {
    var hotspotSSID = ""
    var tryRemembered = true
    var preferWifi = true
    var checkInterval = 45
    var maxInterval = 300
    var passwordSet = false
    var networkLabels: [(match: String, label: String)] = []
}

extension Notification.Name {
    static let limpetConfigChanged = Notification.Name("com.georgeolaru.limpet.configChanged")
}

/// Resolve a gateway to a friendly label. Exact match wins; otherwise the longest
/// matching prefix (so "192.168.68.1=Home" beats a broad "192.168.=LAN").
private func resolveNetworkLabel(_ gateway: String, labels: [(match: String, label: String)]) -> String? {
    guard !gateway.isEmpty else { return nil }
    var best: (len: Int, label: String)?
    for entry in labels where !entry.match.isEmpty {
        if gateway == entry.match || gateway.hasPrefix(entry.match) {
            if best == nil || entry.match.count > best!.len { best = (entry.match.count, entry.label) }
        }
    }
    return best?.label
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
        case "NETWORK_LABEL":
            let kv = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 {
                let match = String(kv[0]).trimmingCharacters(in: .whitespaces)
                let label = String(kv[1]).trimmingCharacters(in: .whitespaces)
                if !match.isEmpty && !label.isEmpty { s.networkLabels.append((match, label)) }
            }
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

// MARK: Networks pane (gateway → friendly label)

private final class NetworksPane: SettingsPane {
    private let rowsStack = NSStackView()
    private var rows: [(container: NSView, gw: NSTextField, label: NSTextField)] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private let currentInfoLabel = NSTextField(wrappingLabelWithString: "")
    private let currentNameField = NSTextField()
    private var currentGW = ""

    override func build() {
        addRow(sectionHeader("Network labels"))
        addRow(captionLabel("Name the networks you use, so the Timeline says “Home” instead of an IP. Easiest way: while you’re ON a network, name it below — Limpet remembers it by its gateway, since macOS hides the Wi-Fi name itself (“<redacted>”)."))

        // ---- Connected right now: one-tap labeling, no IP knowledge needed ----
        addRow(divider())
        addRow(sectionHeader("Connected right now"))
        currentInfoLabel.font = NSFont.systemFont(ofSize: 12)
        currentInfoLabel.textColor = .secondaryLabelColor
        currentInfoLabel.preferredMaxLayoutWidth = paneWidth - 48
        addRow(currentInfoLabel)

        currentNameField.placeholderString = "e.g. Home, Office, Mom’s place"
        currentNameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let labelBtn = NSButton(title: "Name this network", target: self, action: #selector(labelCurrent))
        labelBtn.bezelStyle = .rounded
        labelBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let inputRow = NSStackView(views: [currentNameField, labelBtn])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        addRow(inputRow)
        inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        currentGW = currentGateway()
        refreshCurrentCard()

        // ---- All labels (editable, gateway → name) ----
        addRow(divider())
        addRow(sectionHeader("All labels"))
        let heading = NSStackView(views: [columnHeader("Gateway / prefix", 150), columnHeader("Label", nil)])
        heading.orientation = .horizontal
        heading.spacing = 8
        addRow(heading)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        addRow(rowsStack)

        let existing = loadSettings().networkLabels
        if existing.isEmpty {
            addEntryRow(gw: "", label: "")
        } else {
            for entry in existing { addEntryRow(gw: entry.match, label: entry.label) }
        }

        let addButton = NSButton(title: "Add manually", target: self, action: #selector(addRowTapped))
        addButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addButton, spacer, saveButton])
        buttons.orientation = .horizontal
        addRow(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        addRow(statusLabel)
    }

    private func columnHeader(_ text: String, _ width: CGFloat?) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        if let w = width { l.widthAnchor.constraint(equalToConstant: w).isActive = true }
        return l
    }

    private func addEntryRow(gw: String, label: String) {
        let gwField = NSTextField(string: gw)
        gwField.placeholderString = "192.168.68.1"
        gwField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let labelField = NSTextField(string: label)
        labelField.placeholderString = "Home"
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remove = NSButton(title: "✕", target: self, action: #selector(removeRowTapped(_:)))
        remove.bezelStyle = .rounded
        remove.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [gwField, labelField, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        rows.append((row, gwField, labelField))
    }

    @objc private func addRowTapped() {
        addEntryRow(gw: "", label: "")
        view.window?.layoutIfNeeded()
    }

    @objc private func removeRowTapped(_ sender: NSButton) {
        guard let rowView = sender.superview else { return }
        rowsStack.removeArrangedSubview(rowView)
        rowView.removeFromSuperview()
        rows.removeAll { $0.container === rowView }
        if rows.isEmpty { addEntryRow(gw: "", label: "") }
        view.window?.layoutIfNeeded()
    }

    @objc private func save() {
        var entries: [String] = []
        for r in rows {
            let gw = r.gw.stringValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "=", with: "")
            let lbl = r.label.stringValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
            if gw.isEmpty || lbl.isEmpty { continue }
            entries.append("\"\(gw)=\(lbl)\"")
        }
        let value = entries.isEmpty ? "()" : "( " + entries.joined(separator: " ") + " )"
        let result = setConfig("NETWORK_LABELS", value)
        if result.exitCode == 0 {
            statusLabel.stringValue = entries.isEmpty
                ? "Cleared all labels."
                : "Saved \(entries.count) label\(entries.count == 1 ? "" : "s")."
            NotificationCenter.default.post(name: .limpetConfigChanged, object: nil)
        } else {
            statusLabel.stringValue = "Couldn't save: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    private func refreshCurrentCard() {
        if currentGW.isEmpty {
            currentInfoLabel.stringValue = "Not connected to a network right now — connect first, then come back."
            currentNameField.isEnabled = false
            return
        }
        currentNameField.isEnabled = true
        if let existing = resolveNetworkLabel(currentGW, labels: loadSettings().networkLabels) {
            currentInfoLabel.stringValue = "Already labeled “\(existing)” · gateway \(currentGW). Type a new name to rename it."
            if currentNameField.stringValue.isEmpty { currentNameField.stringValue = existing }
        } else {
            currentInfoLabel.stringValue = "macOS hides this network’s name · gateway \(currentGW). Give it a name you’ll recognize."
        }
    }

    @objc private func labelCurrent() {
        let name = currentNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !currentGW.isEmpty else { statusLabel.stringValue = "Not connected to a network."; return }
        guard !name.isEmpty else { statusLabel.stringValue = "Type a name first."; return }
        upsertRow(gw: currentGW, label: name)
        save()
        refreshCurrentCard()
        view.window?.layoutIfNeeded()
    }

    // Update the row for this gateway if it exists, reuse a blank row, else add one.
    private func upsertRow(gw: String, label: String) {
        for r in rows where r.gw.stringValue.trimmingCharacters(in: .whitespaces) == gw {
            r.label.stringValue = label
            return
        }
        for r in rows where r.gw.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            && r.label.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            r.gw.stringValue = gw
            r.label.stringValue = label
            return
        }
        addEntryRow(gw: gw, label: label)
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
        addTab(NetworksPane(), label: "Networks", symbol: "wifi")
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

// MARK: - Timeline: compact log parse for the menu's mini-timeline

private struct TimelineMoment {
    enum Kind { case onlineWifi, onlineHotspot, offline, gap }
    let kind: Kind
    let time: String
    let text: String
}

private enum TimelineParser {
    private static let hotspotGW = "172.20.10."
    private static let gapSeconds: TimeInterval = 12 * 60

    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    private static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func dur(_ a: Date, _ b: Date) -> String {
        let s = max(0, Int(b.timeIntervalSince(a)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// "HH:mm" for entries on the reference day, "EEE HH:mm" (e.g. "Mon 11:16") for older ones,
    /// so a glance at the menu isn't ambiguous across days.
    private static func label(_ d: Date, reference: Date) -> String {
        if Calendar.current.isDate(d, inSameDayAs: reference) { return clock(d) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }

    /// Returns the current state plus the most recent incidents/gaps (newest first).
    static func parse(_ content: String, labels: [(match: String, label: String)] = [], limit: Int = 5)
        -> (current: TimelineMoment?, moments: [TimelineMoment]) {
        let f = makeFormatter()
        var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > 800 { lines = Array(lines.suffix(800)) }

        var onlineHot = false
        var lastGateway = ""
        var prev: Date?
        var incidentStart: Date?
        var incidentVia: String?
        var lastDate: Date?
        var lastKind: TimelineMoment.Kind = .onlineWifi
        var collected: [(date: Date, kind: TimelineMoment.Kind, text: String)] = []

        // The gateway most representative of a state, for label lookup (hotspot uses its range).
        func labelFor(hot: Bool) -> String? {
            resolveNetworkLabel(hot ? (lastGateway.hasPrefix(hotspotGW) ? lastGateway : "172.20.10.1") : lastGateway, labels: labels)
        }

        for line in lines {
            guard line.count >= 19, let t = f.date(from: String(line.prefix(19))) else { continue }
            let msg = line.dropFirst(20).trimmingCharacters(in: .whitespaces)
            lastDate = t

            if let r = msg.range(of: "gateway=") {
                let gw = String(msg[r.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
                if !gw.isEmpty { lastGateway = gw }
                onlineHot = gw.hasPrefix(hotspotGW)
            }

            if let p = prev, t.timeIntervalSince(p) > gapSeconds, incidentStart == nil {
                collected.append((p, .gap, "Asleep \(dur(p, t))"))
            }
            prev = t

            if msg.hasPrefix("No internet detected") || msg.contains("captive portal)") {
                if incidentStart == nil { incidentStart = t; incidentVia = nil }
                continue
            }

            if let start = incidentStart {
                if msg.hasPrefix("Recovered via macOS Auto-Join") || msg.contains("now on the phone hotspot") {
                    incidentVia = "autojoin"
                } else if msg.hasPrefix("Recovered after Wi-Fi power cycle") {
                    incidentVia = "cycle"
                }
                let recovered = msg.hasPrefix("Recovered")
                    || msg.hasPrefix("Remediation succeeded")
                    || msg.hasPrefix("Internet OK")
                    || msg.hasPrefix("Prefer Wi-Fi check")
                    || msg.hasPrefix("Internet still OK")
                if recovered {
                    let landedHot = onlineHot || incidentVia == "autojoin"
                    var suffix = ""
                    if let l = labelFor(hot: landedHot) { suffix = " → \(l)" }
                    else if landedHot { suffix = " → hotspot" }
                    let text = "Recovered · down \(dur(start, t))" + suffix
                    collected.append((t, landedHot ? .onlineHotspot : .onlineWifi, text))
                    lastKind = landedHot ? .onlineHotspot : .onlineWifi
                    incidentStart = nil
                    incidentVia = nil
                }
                continue
            }

            if msg.hasPrefix("Internet OK") || msg.hasPrefix("Prefer Wi-Fi check")
                || msg.hasPrefix("Current connection looks like hotspot") || msg.hasPrefix("Internet still OK")
                || msg.hasPrefix("Switched from hotspot") || msg.hasPrefix("limpet started") {
                lastKind = onlineHot ? .onlineHotspot : .onlineWifi
            }
        }

        let reference = lastDate ?? Date()
        var current: TimelineMoment?
        if let ld = lastDate {
            if let start = incidentStart {
                current = TimelineMoment(kind: .offline, time: label(start, reference: ld), text: "Offline — fixing · \(dur(start, ld))")
            } else {
                let hot = lastKind == .onlineHotspot
                let name = labelFor(hot: hot) ?? (hot ? "iPhone hotspot" : "Wi-Fi")
                current = TimelineMoment(kind: lastKind, time: label(ld, reference: ld), text: "Online · \(name)")
            }
        }

        let moments = collected.suffix(limit).reversed().map {
            TimelineMoment(kind: $0.kind, time: label($0.date, reference: reference), text: $0.text)
        }
        return (current, moments)
    }
}

// MARK: - Timeline window (live WKWebView)

private final class TimelineWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 940, height: 680))
    private var refreshTimer: Timer?
    private var logPath = defaultLogPath
    private var labels: [(match: String, label: String)] = []
    private var pageReady = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Limpet — Timeline"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        self.init(window: window)

        window.delegate = self
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView = webView
        loadPage()
    }

    private func loadPage() {
        if let url = Bundle.main.url(forResource: "timeline", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let fallback = "<body style=\"font:14px -apple-system;background:#0b1018;color:#e7eef7;padding:40px\">"
                + "Timeline page not found in the app bundle. Reinstall Limpet — the installer copies "
                + "<code>timeline.html</code> into the app.</body>"
            webView.loadHTMLString(fallback, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        pushLog()
    }

    func show(logPath: String, labels: [(match: String, label: String)]) {
        self.logPath = logPath
        self.labels = labels
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible { window.center() }
        window?.makeKeyAndOrderFront(nil)
        pushLog()
        startTimer()
    }

    /// Refresh labels while the window is open (e.g. after the Networks settings change).
    func updateLabels(_ labels: [(match: String, label: String)]) {
        self.labels = labels
        pushLog()
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pushLog()
        }
    }

    private func pushLog() {
        guard pageReady else { return }
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        // JSON-encode the log as a 1-element array, then hand element [0] to the page renderer.
        // This escapes quotes/backslashes/newlines/unicode safely without hand-rolling it.
        guard let data = try? JSONSerialization.data(withJSONObject: [log]),
              let json = String(data: data, encoding: .utf8) else { return }
        let labelObjs = labels.map { ["m": $0.match, "l": $0.label] }
        let labelsJson = (try? JSONSerialization.data(withJSONObject: labelObjs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        webView.evaluateJavaScript(
            "window.LIMPET_RENDER && window.LIMPET_RENDER(\(json)[0], {labels:\(labelsJson)});",
            completionHandler: nil)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit { refreshTimer?.invalidate() }
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
    private var timelineController: TimelineWindowController?
    private var networkLabels: [(match: String, label: String)] = []

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

        networkLabels = loadSettings().networkLabels
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: .limpetConfigChanged, object: nil)

        rebuildMenu()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    @objc private func configChanged() {
        networkLabels = loadSettings().networkLabels
        timelineController?.updateLabels(networkLabels)
        rebuildMenu()
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
        menu.addItem(activitySubmenuItem(status))

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

    /// "Activity ▸" — a live mini-timeline (current state + recent incidents/gaps),
    /// then the full visual timeline window and the raw log file.
    private func activitySubmenuItem(_ status: GuardianStatus?) -> NSMenuItem {
        let parent = NSMenuItem(title: "Activity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let logPath = status?.logFile ?? defaultLogPath
        let content = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let parsed = TimelineParser.parse(content, labels: networkLabels)

        if let current = parsed.current {
            submenu.addItem(momentRow(current, emphasized: true))
            submenu.addItem(NSMenuItem.separator())
        }
        if parsed.moments.isEmpty {
            submenu.addItem(disabledItem("No outages recorded — steady."))
        } else {
            for moment in parsed.moments {
                submenu.addItem(momentRow(moment, emphasized: false))
            }
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(actionItem("Open Full Timeline…", #selector(openTimeline(_:))))
        submenu.addItem(actionItem("Open Raw Log…", #selector(openLog(_:))))

        parent.submenu = submenu
        return parent
    }

    private func momentRow(_ moment: TimelineMoment, emphasized: Bool) -> NSMenuItem {
        let color: NSColor
        switch moment.kind {
        case .onlineWifi: color = .systemGreen
        case .onlineHotspot: color = .systemBlue
        case .offline: color = .systemRed
        case .gap: color = .systemGray
        }
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        let font = emphasized ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                              : NSFont.menuFont(ofSize: 0)
        title.append(NSAttributedString(string: "\(moment.time)  \(moment.text)",
            attributes: [.foregroundColor: NSColor.labelColor, .font: font]))

        // Enabled (full-strength, not dimmed) and clickable → opens the full timeline.
        let item = NSMenuItem(title: moment.text, action: #selector(openTimeline(_:)), keyEquivalent: "")
        item.target = self
        item.attributedTitle = title
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

    @objc private func openTimeline(_ sender: NSMenuItem) {
        if timelineController == nil { timelineController = TimelineWindowController() }
        timelineController?.show(logPath: currentStatus?.logFile ?? defaultLogPath, labels: networkLabels)
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
