import Cocoa
import ServiceManagement
import IOKit

let scriptPath = NSHomeDirectory() + "/.local/bin/insomnia"
let legacyLaunchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/io.github.artemkorchunov.insomnia.plist"
let homePrefix = NSHomeDirectory()

func tildePath(_ path: String) -> String {
    path.hasPrefix(homePrefix) ? "~" + path.dropFirst(homePrefix.count) : path
}

func lidIsClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (value as? Bool) ?? false
}

func lockScreenNow() {
    typealias LockFn = @convention(c) () -> Int32
    if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
       let symbol = dlsym(handle, "SACLockScreenImmediate") {
        _ = unsafeBitCast(symbol, to: LockFn.self)()
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    try? p.run()
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var state: [String: String] = [:]
    var recentDirs: [String] = []
    var userPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    var busy = false
    let defaults = UserDefaults.standard

    var hours: Int {
        get { defaults.integer(forKey: "hours") }
        set { defaults.set(newValue, forKey: "hours") }
    }
    var lowPower: Bool {
        get { defaults.bool(forKey: "lowPower") }
        set { defaults.set(newValue, forKey: "lowPower") }
    }
    var worktree: Bool {
        get { defaults.bool(forKey: "worktree") }
        set { defaults.set(newValue, forKey: "worktree") }
    }
    var lidWasClosed = lidIsClosed()
    var activity: NSObjectProtocol?
    var lockOnLidClose: Bool {
        get { defaults.object(forKey: "lockOnLidClose") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockOnLidClose") }
    }
    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var isRunning: Bool { state["running"] == "1" }
    var sleepDisabled: Bool { state["sleep_disabled"] == "1" }
    var remoteOn: Bool { state["remote"] == "1" }
    var noPassword: Bool { state["nopasswd"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        let positionKey = "NSStatusItem Preferred Position insomnia"
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(260, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.autosaveName = "insomnia"
        statusItem.behavior = []
        menu.delegate = self
        statusItem.menu = menu
        try? FileManager.default.removeItem(atPath: legacyLaunchAgentPath)
        if !defaults.bool(forKey: "loginItemOffered") {
            defaults.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
        updateIcon()
        DispatchQueue.global().async {
            let path = self.loginShellPath()
            let dirs = self.fetchRecentDirs()
            let st = self.fetchState()
            DispatchQueue.main.async {
                if let path { self.userPath = path }
                self.recentDirs = dirs
                self.state = st
                self.updateIcon()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.refresh() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Watch the lid to lock the screen")
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in self.checkLid() }
    }

    func loginShellPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf '__PATH__%s' \"$PATH\""]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard let r = out.range(of: "__PATH__", options: .backwards) else { return nil }
        let path = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    @discardableResult
    func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    func runScript(_ args: [String]) -> (status: Int32, output: String) {
        run("/bin/bash", [scriptPath] + args)
    }

    func runScriptAsAdmin(_ args: [String]) -> (status: Int32, output: String) {
        let command = ([scriptPath] + args).map(shellQuote).joined(separator: " ")
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Insomnia needs admin rights to change sleep settings.\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", source])
    }

    func fetchState() -> [String: String] {
        var result: [String: String] = [:]
        for line in runScript(["state"]).output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] } else if parts.count == 1 { result[parts[0]] = "" }
        }
        return result
    }

    func fetchRecentDirs() -> [String] {
        runScript(["recent-dirs", "10"]).output
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func checkLid() {
        let closed = lidIsClosed()
        if closed && !lidWasClosed && lockOnLidClose {
            DispatchQueue.global().async {
                let st = self.fetchState()
                DispatchQueue.main.async {
                    self.state = st
                    self.updateIcon()
                    if st["running"] == "1" && lidIsClosed() { lockScreenNow() }
                }
            }
        }
        lidWasClosed = closed
    }

    func refresh() {
        DispatchQueue.global().async {
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.updateIcon()
            }
        }
    }

    func updateIcon() {
        let image: NSImage?
        let tip: String
        if busy {
            image = menuIcon(.waking); tip = "Insomnia: working…"
        } else if isRunning {
            image = menuIcon(.awake); tip = remoteOn ? "Insomnia is on, with phone access" : "Insomnia is on"
        } else if sleepDisabled {
            image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil); tip = "Sleep is disabled but Insomnia is not running"
        } else {
            image = menuIcon(.asleep); tip = "Insomnia is off"
        }
        image?.isTemplate = true
        image?.accessibilityDescription = tip
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        state = fetchState()
        updateIcon()
        buildMenu()
        DispatchQueue.global().async {
            let dirs = self.fetchRecentDirs()
            DispatchQueue.main.async { self.recentDirs = dirs }
        }
    }

    func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?, enabled: Bool = true, object: Any? = nil, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        item.representedObject = object
        item.state = checked ? .on : .off
        menu.addItem(item)
        return item
    }

    func buildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let header: String
        if busy {
            header = "Insomnia: working…"
        } else if isRunning {
            header = "Insomnia is ON: Mac stays awake with the lid closed"
        } else if sleepDisabled {
            header = "⚠︎ Sleep disabled, but no watchdog is running"
        } else {
            header = "Insomnia is OFF: Mac sleeps normally"
        }
        _ = addItem(menu, header, nil, enabled: false)

        var info = "Battery \(state["battery"] ?? "?")% · \(state["temp"] ?? "?") °C · \(state["power"] ?? "?")"
        if let lid = state["lid"] { info += " · lid \(lid)" }
        _ = addItem(menu, info, nil, enabled: false)

        if remoteOn {
            let dirs = (state["remote_dirs"] ?? state["remote_dir"] ?? "").split(separator: "|").map { tildePath(String($0)) }
            if dirs.count > 1 {
                let item = NSMenuItem(title: "Phone access on in \(dirs.count) folders", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for dir in dirs { _ = addItem(sub, dir, nil, enabled: false) }
                item.submenu = sub
                menu.addItem(item)
            } else {
                _ = addItem(menu, "Phone access on in \(dirs.first ?? "")", nil, enabled: false)
            }
            _ = addItem(menu, "Copy Phone Link", #selector(copyLink))
        }

        menu.addItem(.separator())

        if isRunning || sleepDisabled {
            _ = addItem(menu, "Turn Off (phone chats stay connected while awake)", #selector(turnOff), enabled: !busy)
        }
        if remoteOn {
            _ = addItem(menu, "Stop Phone Access", #selector(stopPhoneAccess), enabled: !busy)
        }
        if isRunning {
            _ = addItem(menu, remoteOn ? "Add Phone Access in All Recent Folders" : "Phone Access in All Recent Folders", #selector(phoneAccessAll), enabled: !busy)
        }
        if !isRunning {
            _ = addItem(menu, "Turn On", #selector(turnOnPlain), enabled: !busy)

            let phoneItem = NSMenuItem(title: "Turn On + Phone Access in", action: nil, keyEquivalent: "")
            phoneItem.isEnabled = !busy
            let sub = NSMenu()
            sub.autoenablesItems = false
            if recentDirs.isEmpty {
                _ = addItem(sub, "No recent folders", nil, enabled: false)
            } else {
                let all = addItem(sub, "All Recent Folders", #selector(turnOnWithDir(_:)), enabled: !busy, object: "all")
                all.toolTip = "One phone server per folder below (except your home folder), so the phone can open chats in any of them"
                sub.addItem(.separator())
            }
            for dir in recentDirs {
                let item = addItem(sub, tildePath(dir), #selector(turnOnWithDir(_:)), enabled: !busy, object: dir)
                item.toolTip = dir
            }
            sub.addItem(.separator())
            _ = addItem(sub, "Choose Folder…", #selector(chooseFolder), enabled: !busy)
            phoneItem.submenu = sub
            menu.addItem(phoneItem)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        sm.autoenablesItems = false
        _ = addItem(sm, "Low Power Mode While On", #selector(toggleLowPower), checked: lowPower)
        _ = addItem(sm, "Phone Sessions in Separate Worktrees", #selector(toggleWorktree), checked: worktree)
        _ = addItem(sm, "Lock Screen When Lid Closes", #selector(toggleLockOnLidClose), checked: lockOnLidClose)
        let stopItem = NSMenuItem(title: "Stop After", action: nil, keyEquivalent: "")
        let stopMenu = NSMenu()
        stopMenu.autoenablesItems = false
        for h in [0, 1, 2, 4, 8, 12] {
            _ = addItem(stopMenu, h == 0 ? "No Limit" : "\(h) hour\(h == 1 ? "" : "s")", #selector(setHours(_:)), object: h, checked: hours == h)
        }
        stopItem.submenu = stopMenu
        sm.addItem(stopItem)
        sm.addItem(.separator())
        _ = addItem(sm, "Open at Login", #selector(toggleOpenAtLogin), checked: openAtLogin)
        settings.submenu = sm
        menu.addItem(settings)

        _ = addItem(menu, "Lock Screen Now", #selector(lockNow))
        _ = addItem(menu, "Open Log", #selector(openLog))
        menu.addItem(.separator())
        _ = addItem(menu, "Quit Insomnia Menu", #selector(quit))
    }

    func setBusy(_ value: Bool) {
        busy = value
        updateIcon()
    }

    func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Insomnia"
        alert.informativeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = .warning
        alert.runModal()
    }

    func turnOn(dir: String?) {
        setBusy(true)
        let hours = self.hours, lowPower = self.lowPower, worktree = self.worktree
        let quiet = noPassword
        DispatchQueue.global().async {
            var error: String?
            if quiet {
                var args = ["on"]
                if let dir {
                    args += ["--remote", dir]
                    if worktree { args += ["--remote-spawn", "worktree"] }
                }
                if hours > 0 { args += ["--hours", String(hours)] }
                if lowPower { args.append("--low-power") }
                let r = self.runScript(args)
                let st = self.fetchState()
                DispatchQueue.main.async {
                    self.state = st
                    self.setBusy(false)
                    if r.status != 0 { self.showError(r.output) }
                }
                return
            }
            if let dir {
                var args = ["remote-on", dir]
                if worktree { args += ["--remote-spawn", "worktree"] }
                let r = self.runScript(args)
                if r.status != 0 { error = r.output }
            }
            if error == nil {
                var args = ["on"]
                if hours > 0 { args += ["--hours", String(hours)] }
                if lowPower { args.append("--low-power") }
                let r = self.runScriptAsAdmin(args)
                if r.status != 0 {
                    error = r.output.contains("-128") ? "" : r.output
                    if dir != nil { self.runScript(["remote-off"]) }
                }
            }
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.setBusy(false)
                if let error, !error.isEmpty { self.showError(error) }
            }
        }
    }

    @objc func turnOnPlain() { turnOn(dir: nil) }

    @objc func turnOnWithDir(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? String { turnOn(dir: dir) }
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Turn On Here"
        panel.message = "Folder where phone-created Claude sessions will run"
        if let first = recentDirs.first { panel.directoryURL = URL(fileURLWithPath: first) }
        if panel.runModal() == .OK, let url = panel.url {
            turnOn(dir: url.path)
        }
    }

    @objc func turnOff() {
        let needsAdmin = isRunning || sleepDisabled
        let quiet = noPassword
        setBusy(true)
        DispatchQueue.global().async {
            let r = !needsAdmin ? self.runScript(["remote-off"]) : (quiet ? self.runScript(["off"]) : self.runScriptAsAdmin(["off"]))
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.setBusy(false)
                if r.status != 0, !r.output.contains("-128") { self.showError(r.output) }
            }
        }
    }

    @objc func phoneAccessAll() {
        setBusy(true)
        let worktree = self.worktree
        DispatchQueue.global().async {
            var args = ["remote-on", "all"]
            if worktree { args += ["--remote-spawn", "worktree"] }
            let r = self.runScript(args)
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.setBusy(false)
                if r.status != 0 { self.showError(r.output) }
            }
        }
    }

    @objc func stopPhoneAccess() {
        setBusy(true)
        DispatchQueue.global().async {
            self.runScript(["remote-off"])
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.setBusy(false)
            }
        }
    }

    @objc func copyLink() {
        guard let url = state["remote_url"], !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func toggleLowPower() { lowPower.toggle() }
    @objc func toggleWorktree() { worktree.toggle() }
    @objc func toggleLockOnLidClose() { lockOnLidClose.toggle() }
    @objc func lockNow() { lockScreenNow() }

    @objc func setHours(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? Int { hours = h }
    }

    @objc func toggleOpenAtLogin() {
        do {
            if openAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not change Open at Login: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc func openLog() {
        let log = "/tmp/insomnia-watchdog.log"
        if !FileManager.default.fileExists(atPath: log) {
            FileManager.default.createFile(atPath: log, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
