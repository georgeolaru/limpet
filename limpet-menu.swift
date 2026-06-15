import AppKit
import Darwin
import Foundation

private let daemonLabel = "com.georgeolaru.limpet"
private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
private let defaultScriptPath = "\(homeDirectory)/.local/bin/limpet.sh"
private let scriptPath = ProcessInfo.processInfo.environment["LIMPET_SCRIPT"] ?? defaultScriptPath
private let configPath = "\(homeDirectory)/.config/limpet/config.sh"
private let defaultLogPath = "\(homeDirectory)/Library/Logs/limpet.log"
private let daemonPlistPath = "\(homeDirectory)/Library/LaunchAgents/\(daemonLabel).plist"

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return CommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }
}

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
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let workQueue = DispatchQueue(label: "limpet-menu.worker", qos: .utility)
    private var timer: Timer?
    private var currentStatus: GuardianStatus?
    private var refreshInFlight = false
    private var lastActionMessage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.title = " ..."
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
        let internet = status.internet.uppercased()
        let title: String
        let symbolName: String

        if internet.contains("OK") {
            title = " OK"
            symbolName = "wifi"
        } else if internet.contains("CAPTIVE") {
            title = " LOGIN"
            symbolName = "exclamationmark.triangle"
        } else if internet.contains("DOWN") || internet.contains("UNAVAILABLE") {
            title = " DOWN"
            symbolName = "wifi.slash"
        } else {
            title = " ?"
            symbolName = "questionmark.circle"
        }

        button.title = title
        button.toolTip = "Limpet: \(status.internet)"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Limpet") {
            image.isTemplate = true
            button.image = image
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status = currentStatus
        menu.addItem(disabledItem("Limpet"))
        menu.addItem(disabledItem("Internet: \(status?.internet ?? "Checking...")"))
        menu.addItem(disabledItem("Agent: \(status?.agentState ?? "checking") \(pidSuffix(status?.agentPid))"))
        menu.addItem(disabledItem("Wi-Fi: \(status?.interface ?? "-") / \(status?.wifiPower ?? "-")"))
        menu.addItem(disabledItem("IP: \(status?.ipAddress ?? "-")"))
        menu.addItem(disabledItem("Route: \(status?.defaultRoute ?? "-")"))
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
        menu.addItem(actionItem("Refresh Status", #selector(refreshStatusAction(_:))))
        menu.addItem(actionItem("Check Internet Now", #selector(checkInternetNow(_:))))
        menu.addItem(actionItem("Prefer Wi-Fi Now", #selector(preferWifiNow(_:))))
        menu.addItem(actionItem("Restart Agent", #selector(restartAgent(_:))))
        menu.addItem(actionItem("Stop Agent", #selector(stopAgent(_:))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Show Details", #selector(showDetails(_:))))
        menu.addItem(actionItem("Open Log", #selector(openLog(_:))))
        menu.addItem(actionItem("Edit Config", #selector(openConfig(_:))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit Menu", #selector(quitMenu(_:))))
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

    @objc private func refreshStatusAction(_ sender: NSMenuItem) {
        if refreshInFlight {
            lastActionMessage = "Refresh Status: already running"
            rebuildMenu()
            return
        }
        lastActionMessage = "Refresh Status: running..."
        rebuildMenu()
        refreshStatus(completionMessage: "Refresh Status: updated")
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

    @objc private func restartAgent(_ sender: NSMenuItem) {
        performAction("Restart Agent") {
            let uid = String(getuid())
            let specifier = "gui/\(uid)/\(daemonLabel)"
            let printResult = Shell.run("/bin/launchctl", ["print", specifier])
            if printResult.exitCode != 0 {
                let bootstrap = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlistPath])
                if bootstrap.exitCode != 0 {
                    return bootstrap
                }
            }
            return Shell.run("/bin/launchctl", ["kickstart", "-k", specifier])
        }
    }

    @objc private func stopAgent(_ sender: NSMenuItem) {
        performAction("Stop Agent") {
            let specifier = "gui/\(getuid())/\(daemonLabel)"
            return Shell.run("/bin/launchctl", ["bootout", specifier])
        }
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
        alert.runModal()
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        let path = currentStatus?.logFile ?? defaultLogPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openConfig(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
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
