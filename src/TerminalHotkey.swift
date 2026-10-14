import AppKit
import Carbon
import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(message)\n".utf8))
}

func openNewTerminal() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-a", "/System/Applications/Utilities/Terminal.app", FileManager.default.homeDirectoryForCurrentUser.path]
    do {
        try task.run()
        task.waitUntilExit()
        log("open-new-terminal exit=\(task.terminationStatus)")
    } catch { log("open-new-terminal failed: \(error)") }
}

let windowQuery = """
tell application "Terminal"
    set resultRows to {}
    set terminalWindowIDs to get id of every window
    repeat with windowIDRef in terminalWindowIDs
        set terminalWindowID to contents of windowIDRef
        if terminalWindowID is not missing value then
            try
                set terminalWindowID to terminalWindowID as integer
                -- Explicit IDs avoid ambiguous "item N of every window" references.
                -- Settings windows and windows closed during the query have no tabs.
                set terminalTabCount to count tabs of window id terminalWindowID
                if terminalTabCount > 0 then
                    set windowBusy to false
                    set windowTTYs to {}
                    repeat with terminalTabIndex from 1 to terminalTabCount
                        if (get busy of tab terminalTabIndex of window id terminalWindowID) then set windowBusy to true
                        set end of windowTTYs to (get tty of tab terminalTabIndex of window id terminalWindowID)
                    end repeat
                    set end of resultRows to {terminalWindowID, windowBusy, windowTTYs}
                end if
            on error errorMessage number errorNumber
                if errorNumber is not -1728 then error errorMessage number errorNumber
            end try
        end if
    end repeat
    return resultRows
end tell
"""

func runScript(_ source: String) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else {
        throw NSError(domain: "TerminalHotkey", code: 1)
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error = error {
        throw NSError(domain: "TerminalHotkey", code: error[NSAppleScript.errorNumber] as? Int ?? 1,
                      userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Automation failed"])
    }
    return result
}

// The oldest session in each window gives its creation order, even if an older
// window has acquired a newer tab or has been brought to the front.
func sessionStarts() -> [String: (Date, Int)] {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,tty=,lstart="]
    task.standardOutput = pipe
    task.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
    do { try task.run() } catch { return [:] }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    var starts: [String: (Date, Int)] = [:]
    for line in output.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 7, let pid = Int(fields[0]), fields[1] != "??",
              let date = formatter.date(from: fields.dropFirst(2).joined(separator: " ")) else { continue }
        let tty = "/dev/" + fields[1]
        if let prior = starts[tty], prior.0 < date || (prior.0 == date && prior.1 <= pid) { continue }
        starts[tty] = (date, pid)
    }
    return starts
}

struct TerminalWindow {
    let id: Int32
    let busy: Bool
    let started: Date?
    let initialPID: Int
}

func newestWindow(from rows: NSAppleEventDescriptor) -> TerminalWindow? {
    guard rows.numberOfItems > 0 else { return nil }
    let starts = sessionStarts()
    var windows: [TerminalWindow] = []
    for index in 1...rows.numberOfItems {
        guard let row = rows.atIndex(index), let id = row.atIndex(1), let busy = row.atIndex(2),
              let ttys = row.atIndex(3) else { continue }
        var sessions: [(Date, Int)] = []
        if ttys.numberOfItems > 0 {
            for tabIndex in 1...ttys.numberOfItems {
                if let tty = ttys.atIndex(tabIndex)?.stringValue, let started = starts[tty] { sessions.append(started) }
            }
        }
        let oldest = sessions.min { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        windows.append(TerminalWindow(id: id.int32Value, busy: busy.booleanValue, started: oldest?.0, initialPID: oldest?.1 ?? 0))
    }
    let haveAllStartTimes = windows.allSatisfy { $0.started != nil }
    return windows.max { lhs, rhs in
        if haveAllStartTimes, let left = lhs.started, let right = rhs.started {
            return left == right ? lhs.initialPID < rhs.initialPID : left < right
        }
        return lhs.id < rhs.id
    }
}

func showAlert(_ title: String, _ detail: String, confirm: Bool = false) -> Bool {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: confirm ? "取消" : "好")
    if confirm { alert.addButton(withTitle: "关闭窗口") }
    return alert.runModal() == .alertSecondButtonReturn
}

var actionInProgress = false

func closeNewestTerminal() {
    guard !actionInProgress else { return }
    actionInProgress = true
    defer { actionInProgress = false }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty == false else {
        log("close-newest-terminal: Terminal is not running")
        return
    }
    do {
        let rows = try runScript(windowQuery)
        guard rows.numberOfItems > 0 else { log("close-newest-terminal: no windows"); return }
        guard let newest = newestWindow(from: rows) else { return }
        if newest.busy && !showAlert("终端中有正在运行的命令", "关闭最近打开的终端窗口会中断其中的进程。", confirm: true) { return }
        _ = try runScript("tell application \"Terminal\" to close (first window whose id is \(newest.id))")
        log("close-newest-terminal window=\(newest.id)")
    } catch {
        log("close-newest-terminal failed: \(error)")
        let message = (error as NSError).code == -1743
            ? "请在系统设置 → 隐私与安全性 → 自动化中，允许 Terminal Hotkeys 控制 Terminal，然后再次按 Control + Option + W。"
            : error.localizedDescription
        _ = showAlert("无法关闭终端窗口", message)
    }
}

if CommandLine.arguments.contains("--open-terminal") { openNewTerminal(); exit(0) }
// Compile scripting code without sending any commands to Terminal.
if CommandLine.arguments.contains("--validate") {
    for source in [windowQuery, "tell application \"Terminal\" to close (first window whose id is 123)"] {
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.compileAndReturnError(&error) == true else {
            log("script compilation failed: \(String(describing: error))")
            exit(1)
        }
    }
    log("script syntax validated")
    exit(0)
}

if CommandLine.arguments.contains("--self-check") {
    func ids(_ rows: NSAppleEventDescriptor) -> Set<Int32> {
        Set((0..<rows.numberOfItems).compactMap { rows.atIndex($0 + 1)?.atIndex(1)?.int32Value })
    }
    do {
        let before = ids(try runScript(windowQuery))
        openNewTerminal()
        var rows = try runScript(windowQuery)
        for _ in 0..<20 {
            if ids(rows).subtracting(before).count == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
            rows = try runScript(windowQuery)
        }
        let added = ids(rows).subtracting(before)
        guard added.count == 1, let target = newestWindow(from: rows), added.contains(target.id) else {
            log("self-check failed: new-window selection mismatch; no windows closed")
            exit(1)
        }
        // Give the new shell time to finish its startup scripts.
        for _ in 0..<30 {
            if newestWindow(from: rows)?.busy == false { break }
            Thread.sleep(forTimeInterval: 0.1)
            rows = try runScript(windowQuery)
        }
        guard let ready = newestWindow(from: rows), ready.id == target.id, !ready.busy else {
            log("self-check stopped: test window busy or selection changed; no windows closed")
            exit(1)
        }
        _ = try runScript("tell application \"Terminal\" to close (first window whose id is \(ready.id))")
        var after = ids(try runScript(windowQuery))
        for _ in 0..<20 {
            if after == before { break }
            Thread.sleep(forTimeInterval: 0.1)
            after = ids(try runScript(windowQuery))
        }
        guard after == before else { log("self-check failed: unexpected window set"); exit(1) }
        log("self-check passed: selected and closed only the newly created idle window; existing windows unchanged")
        exit(0)
    } catch { log("self-check failed: \(error)"); exit(1) }
}

if CommandLine.arguments.contains("--diagnose") {
    do {
        let rows = try runScript(windowQuery)
        log("diagnose: readable-terminal-windows=\(rows.numberOfItems)")
        for index in 0..<rows.numberOfItems {
            if let row = rows.atIndex(index + 1) {
                log("diagnose: window=\(row.atIndex(1)?.int32Value ?? 0) busy=\(row.atIndex(2)?.booleanValue ?? false) tabs=\(row.atIndex(3)?.numberOfItems ?? 0)")
            }
        }
        exit(0)
    } catch { log("diagnose failed: \(error)"); exit(1) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var keysDown = Set<UInt32>()
var lastActionTime: TimeInterval = -1
let handler: EventHandlerUPP = { _, event, _ in
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var receivedID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
    guard status == noErr, receivedID.signature == 0x54484B59, [1, 2].contains(receivedID.id) else {
        return OSStatus(eventNotHandledErr)
    }
    if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
        keysDown.remove(receivedID.id)
    } else if !keysDown.contains(receivedID.id) {
        keysDown.insert(receivedID.id)
        let now = ProcessInfo.processInfo.systemUptime
        guard !actionInProgress, now - lastActionTime >= 0.4 else { return noErr }
        lastActionTime = now
        if receivedID.id == 1 { openNewTerminal() } else { closeNewestTerminal() }
    }
    return noErr
}
let eventTypes = [
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
]
var eventHandlerRef: EventHandlerRef?
let handlerStatus = eventTypes.withUnsafeBufferPointer { events in
    InstallEventHandler(GetApplicationEventTarget(), handler, events.count, events.baseAddress, nil, &eventHandlerRef)
}
guard handlerStatus == noErr else { log("event-handler failed status=\(handlerStatus)"); exit(1) }
var hotKeyRefs: [EventHotKeyRef?] = []
for (keyCode, id, name) in [(kVK_ANSI_T, UInt32(1), "Control+Option+T"), (kVK_ANSI_W, UInt32(2), "Control+Option+W")] {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x54484B59, id: id), GetApplicationEventTarget(), 0, &ref)
    guard status == noErr else { log("hotkey-registration failed \(name) status=\(status)"); exit(1) }
    hotKeyRefs.append(ref)
    log("registered \(name)")
}
app.run()
