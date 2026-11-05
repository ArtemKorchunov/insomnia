import Cocoa
import ServiceManagement
import IOKit
import SwiftUI
import UserNotifications
import CoreImage

let scriptPath = NSHomeDirectory() + "/.local/bin/insomnia"
let legacyLaunchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/io.github.artemkorchunov.insomnia.plist"
let homePrefix = NSHomeDirectory()
let stopChoices = [0, 1, 2, 4, 8, 12]

/// A crisp QR code for a link, so the phone's camera can open it.
func qrImage(for text: String, size: CGFloat = 180) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

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

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    @Published var state: [String: String] = [:] { didSet { stateChanged(from: oldValue) } }
    /// Set while the user turns Insomnia off, so only stops it made on its own get a notification.
    var userStopping = false
    var warnedDeadline: TimeInterval = 0
    @Published var recentDirs: [String] = []
    @Published var busy = false
    @Published var now = Date()
    var userPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let defaults = UserDefaults.standard

    var hours: Int {
        get { defaults.integer(forKey: "hours") }
        set { defaults.set(newValue, forKey: "hours"); objectWillChange.send() }
    }
    var lowPower: Bool {
        get { defaults.bool(forKey: "lowPower") }
        set { defaults.set(newValue, forKey: "lowPower"); objectWillChange.send() }
    }
    var worktree: Bool {
        get { defaults.bool(forKey: "worktree") }
        set { defaults.set(newValue, forKey: "worktree"); objectWillChange.send() }
    }
    var lidWasClosed = lidIsClosed()
    var activity: NSObjectProtocol?
    var showTimeInMenuBar: Bool {
        get { defaults.object(forKey: "showTimeInMenuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTimeInMenuBar"); objectWillChange.send(); updateIcon() }
    }
    var lockOnLidClose: Bool {
        get { defaults.object(forKey: "lockOnLidClose") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockOnLidClose"); objectWillChange.send() }
    }
    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var isRunning: Bool { state["running"] == "1" }
    var sleepDisabled: Bool { state["sleep_disabled"] == "1" }
    var remoteOn: Bool { state["remote"] == "1" }
    var noPassword: Bool { state["nopasswd"] == "1" }
    var remoteDirs: [String] {
        (state["remote_dirs"] ?? state["remote_dir"] ?? "").split(separator: "|").map(String.init)
    }
    /// A session started before limits could change: its stop time is shown but fixed.
    var limitFixed: Bool { isRunning && state["deadline_fixed"] == "1" }
    /// When the running session stops on its own; nil for no limit or not known.
    var deadline: Date? {
        guard let s = state["deadline"], let t = TimeInterval(s), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        // The popover takes its size from the SwiftUI content and follows it as
        // sections expand; without this it opens at a stale size and slides up over
        // the menu bar.
        let host = NSHostingController(rootView: PanelView(app: self))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "insomnia.ending",
            actions: [UNNotificationAction(identifier: "extend", title: "+1 hour")],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.refresh() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Watch the lid to lock the screen")
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in self.checkLid() }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        refresh()
        DispatchQueue.global().async {
            let dirs = self.fetchRecentDirs()
            DispatchQueue.main.async { self.recentDirs = dirs }
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
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

    // A stop you didn't ask for (time limit, battery, heat) and a time limit about
    // to run out both get a notification, so neither surprises you on the phone.
    func stateChanged(from old: [String: String]) {
        guard !busy, !userStopping else { return }
        if old["running"] == "1" && state["running"] == "0" {
            var body = "The Mac sleeps normally again."
            let parts = (state["last_stop"] ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { body = "Stopped at \(parts[0]): \(parts[1]). " + body }
            // "insomnia off" from a terminal is still you turning it off.
            if !(parts.last ?? "").contains("insomnia off") {
                notify(title: "Insomnia turned off", body: body)
            }
        }
        if isRunning, let end = deadline {
            let left = end.timeIntervalSinceNow
            if left > 0, left <= 600, warnedDeadline != end.timeIntervalSince1970 {
                warnedDeadline = end.timeIntervalSince1970
                notify(title: "Insomnia stops at \(end.formatted(date: .omitted, time: .shortened))",
                       body: "About \(max(1, Int(left / 60))) min left. Phone access stops with it.",
                       category: "insomnia.ending")
            }
        }
    }

    func notify(title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "extend" {
            DispatchQueue.main.async { self.extendByOneHour() }
        }
        completionHandler()
    }

    func refresh() {
        DispatchQueue.global().async {
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.now = Date()
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
        // The time left sits next to the eye, so "when does it stop" needs no click.
        // Only while a limit runs: the bar right of the notch has little room.
        var title = ""
        if !busy, isRunning, showTimeInMenuBar, let end = deadline {
            let minutes = max(0, Int(end.timeIntervalSinceNow / 60))
            title = minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
        }
        statusItem.button?.title = title
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        statusItem.length = title.isEmpty ? 30 : NSStatusItem.variableLength
    }

    func setBusy(_ value: Bool) {
        busy = value
        updateIcon()
    }

    func showError(_ text: String) {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Insomnia"
        alert.informativeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Runs a script command off the main thread, then refreshes the state.
    func perform(_ args: [String], showFailure: Bool = true) {
        setBusy(true)
        DispatchQueue.global().async {
            let r = self.runScript(args)
            let st = self.fetchState()
            DispatchQueue.main.async {
                self.state = st
                self.setBusy(false)
                if showFailure && r.status != 0 { self.showError(r.output) }
            }
        }
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

    /// Phone access in DIR (or "all"): on its own while Insomnia runs, with Insomnia otherwise.
    func phoneAccess(in dir: String) {
        if !isRunning { turnOn(dir: dir); return }
        var args = ["remote-on", dir]
        if worktree { args += ["--remote-spawn", "worktree"] }
        perform(args)
    }

    func chooseFolder() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Folder where phone-created Claude sessions will run"
        if let first = recentDirs.first { panel.directoryURL = URL(fileURLWithPath: first) }
        if panel.runModal() == .OK, let url = panel.url {
            phoneAccess(in: url.path)
        }
    }

    func turnOff() {
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

    var started: Date? {
        guard let s = state["started"], let t = TimeInterval(s), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Saves the choice for the next start and applies it to a running session.
    /// A session from before set-hours can't take a new limit, so it is restarted
    /// with it (phone access keeps running across the restart).
    func setHours(_ h: Int) {
        hours = h
        // Off: picking a time is the start button, so one click starts a session.
        guard isRunning else { turnOn(dir: nil); return }
        if limitFixed {
            restart()
        } else {
            perform(["set-hours", String(h)])
        }
    }

    func restart() {
        let quiet = noPassword
        setBusy(true)
        DispatchQueue.global().async {
            let r = quiet ? self.runScript(["off"]) : self.runScriptAsAdmin(["off"])
            DispatchQueue.main.async {
                self.setBusy(false)
                if r.status != 0 {
                    if !r.output.contains("-128") { self.showError(r.output) }
                    self.refresh()
                } else {
                    self.turnOn(dir: nil)
                }
            }
        }
    }

    func extendByOneHour() {
        guard let end = deadline else { return }
        let hoursLeft = max(0, end.timeIntervalSinceNow) / 3600 + 1
        if limitFixed {
            restart()
        } else {
            perform(["set-hours", String(format: "%.3f", hoursLeft)])
        }
    }

    func copyLink() {
        guard let url = state["remote_url"], !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError("Could not change Open at Login: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        objectWillChange.send()
    }

    func openLog() {
        closePopover()
        let log = "/tmp/insomnia-watchdog.log"
        if !FileManager.default.fileExists(atPath: log) {
            FileManager.default.createFile(atPath: log, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }
}

// MARK: - Panel

let nightAccent = Color(red: 0.42, green: 0.40, blue: 0.95)

struct PanelView: View {
    @ObservedObject var app: AppDelegate
    @State var showQR = false
    // Everything on one page, settings included: nothing opens or collapses, so
    // the panel never changes size and nothing on it moves.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            durationRow
            phoneRow
            safetyRow
            Divider()
            VStack(spacing: 8) {
                switchRow(app.isRunning ? "Low Power Mode (from next start)" : "Low Power Mode while on",
                          Binding(get: { app.lowPower }, set: { app.lowPower = $0 }))
                switchRow("Phone chats in separate worktrees", Binding(get: { app.worktree }, set: { app.worktree = $0 }))
                switchRow("Time left in the menu bar", Binding(get: { app.showTimeInMenuBar }, set: { app.showTimeInMenuBar = $0 }))
                switchRow("Lock screen when the lid closes", Binding(get: { app.lockOnLidClose }, set: { app.lockOnLidClose = $0 }))
                switchRow("Open at login", Binding(get: { app.openAtLogin }, set: { app.setOpenAtLogin($0) }))
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // The one thing worth looking at: on or off, and how long it has left.
    var hero: some View {
        HStack(spacing: 14) {
            TimeRing(progress: ringProgress, on: app.isRunning, busy: app.busy)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(heroTitle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(heroSubtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // Always in place (only disabled while busy), so nothing jumps.
            Toggle("", isOn: Binding(get: { app.isRunning },
                                     set: { $0 ? app.turnOn(dir: nil) : app.turnOff() }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(app.busy)
                .help(app.isRunning ? "Turn off and let the Mac sleep normally" : "Keep the Mac awake with the lid closed")
        }
    }

    var ringProgress: Double {
        guard app.isRunning, let end = app.deadline, let start = app.started, end > start else {
            return app.isRunning ? 1 : 0
        }
        return max(0, min(1, end.timeIntervalSince(app.now) / end.timeIntervalSince(start)))
    }

    var heroTitle: String {
        if app.busy { return "One moment…" }
        guard app.isRunning else { return "Sleeping normally" }
        if let end = app.deadline { return "\(remaining(until: end)) left" }
        return "Awake"
    }

    var heroSubtitle: String {
        if app.busy { return "Changing sleep settings" }
        if app.isRunning {
            if let end = app.deadline {
                return "Sleeps at \(end.formatted(date: .omitted, time: .shortened)). Safe to close the lid."
            }
            return "No time limit. Safe to close the lid."
        }
        if let last = app.state["last_stop"], !last.isEmpty {
            let parts = last.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { return "Stopped at \(parts[0]): \(parts[1])." }
        }
        return "Turn on to keep working with the lid closed."
    }

    var warning: String? {
        if !app.isRunning && app.sleepDisabled {
            return "Sleep is still disabled with nothing watching it. Turn Insomnia off to fix it."
        }
        return nil
    }

    func remaining(until end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(app.now) / 60))
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    // Duration comes before the decision to leave, so it sits right under the switch.
    var durationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.isRunning ? "Stay awake for" : "Turn on for").font(.callout.weight(.medium))
                Spacer()
                let canExtend = app.isRunning && app.deadline != nil && !app.busy
                Button("+1 h") { app.extendByOneHour() }
                    .controlSize(.small)
                    .help("Push the stop time one hour later")
                    .disabled(!canExtend)
                    .opacity(canExtend ? 1 : 0)
            }
            // Off, nothing is selected, so every segment (even the remembered one) starts a session.
            Picker("Stay awake for", selection: Binding(get: { app.isRunning ? app.hours : -1 }, set: { app.setHours($0) })) {
                ForEach(stopChoices, id: \.self) { h in Text(h == 0 ? "No limit" : "\(h) h").tag(h) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(durationNote).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
    }

    var durationNote: String {
        if app.limitFixed { return "Started before limits could change, so picking one restarts it. Phone access stays on." }
        if app.isRunning { return "Counts from now. Phone access stops with it." }
        return "Pick a time to turn on now. Then it sleeps again and phone access stops."
    }

    var phoneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: app.remoteOn ? "iphone.radiowaves.left.and.right" : "iphone")
                .foregroundStyle(app.remoteOn ? nightAccent : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.remoteOn ? phoneSummary : "Phone access off").font(.callout.weight(.medium))
                Text(app.remoteOn ? "Open these chats from the Claude app on your phone."
                                  : "Lets your phone open and start Claude chats on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            Spacer(minLength: 0)
            if app.remoteOn, let url = app.state["remote_url"], !url.isEmpty {
                Button { showQR.toggle() } label: { Image(systemName: "qrcode") }
                    .help("Show a code to scan with your phone")
                    .popover(isPresented: $showQR, arrowEdge: .bottom) { qrCard(url) }
            }
            Menu {
                if app.remoteOn {
                    Button("Copy Phone Link") { app.copyLink() }
                    Divider()
                    Section("In") {
                        ForEach(app.remoteDirs, id: \.self) { Text(tildePath($0)) }
                    }
                    Divider()
                }
                Section(app.remoteOn ? "Add" : (app.isRunning ? "Turn on in" : "Turn on Insomnia with phone access in")) {
                    if !app.recentDirs.isEmpty {
                        Button("All Recent Folders") { app.phoneAccess(in: "all") }
                        ForEach(app.recentDirs, id: \.self) { dir in
                            Button(tildePath(dir)) { app.phoneAccess(in: dir) }
                        }
                    }
                    Button("Choose Folder…") { app.chooseFolder() }
                }
                if app.remoteOn {
                    Divider()
                    Button("Stop Phone Access") { app.perform(["remote-off"], showFailure: false) }
                }
            } label: {
                Text(app.remoteOn ? "Manage" : "Turn On")
            }
            .menuStyle(.borderedButton)
            .frame(width: 84)
        }
    }

    func qrCard(_ url: String) -> some View {
        VStack(spacing: 10) {
            if let image = qrImage(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Point your phone's camera here to open Claude on this Mac.")
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Link Instead") { app.copyLink(); showQR = false }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 230)
    }

    var phoneSummary: String {
        let dirs = app.remoteDirs
        if dirs.count == 1 { return "Phone access in \(URL(fileURLWithPath: dirs[0]).lastPathComponent)" }
        return "Phone access in \(dirs.count) folders"
    }

    // What will stop it on its own, so closing the lid doesn't feel like a gamble.
    var safetyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery \(app.state["battery"] ?? "?")%, \(app.state["temp"] ?? "?") °C, on \(app.state["power"] == "AC" ? "charger" : "battery")")
                    .font(.callout.weight(.medium))
                Text("Sleeps by itself below \(app.state["min_battery"] ?? "20")% on battery, above \(app.state["max_temp"] ?? "45") °C, or when it runs hot.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
    }

    func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    var footer: some View {
        HStack {
            Button("Lock Screen") { app.closePopover(); lockScreenNow() }
            Button("Open Log") { app.openLog() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

/// Insomnia's eye inside a ring that drains as the time limit runs out.
struct TimeRing: View {
    var progress: Double
    var on: Bool
    var busy: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: on ? progress : 0)
                .stroke(nightAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)
            Image(nsImage: menuIcon(on ? .awake : (busy ? .waking : .asleep)))
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? nightAccent : .secondary)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
