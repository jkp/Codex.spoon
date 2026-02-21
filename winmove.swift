// winmove — move/resize windows instantly via Accessibility API with per-app parallelism
//
// Reads JSON from a file argument or stdin:
//   [{"wid": 1234, "pid": 567, "x": 100, "y": 200, "w": 800, "h": 600, "save": true}, ...]
//
// w/h of 0 means "position only, don't resize" (used for parking at screen corner).
// save=true means "report current frame on stdout before moving".
// read_only=true means "just read frame, don't move" (parallel frame reads).
//
// Groups operations by PID, dispatches to concurrent threads, disables
// AXEnhancedUserInterface per-app for zero animation. Matches AeroSpace's approach.
//
// Build: swiftc -O -o winmove winmove.swift -framework ApplicationServices
// Usage: echo '[...]' | winmove
//    or: winmove /path/to/ops.json

import Foundation
import ApplicationServices

struct WindowOp: Decodable {
    let wid: UInt32
    let pid: Int32
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let save: Bool?
    let read_only: Bool?
}

struct SavedFrame: Encodable {
    let wid: UInt32
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

func findAXWindow(app: AXUIElement, targetWID: UInt32) -> AXUIElement? {
    var windows: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
    guard err == .success, let windowList = windows as? [AXUIElement] else {
        if err == .cannotComplete {
            fputs("warn: AX timeout listing windows for app\n", stderr)
        }
        return nil
    }
    for window in windowList {
        var wid: UInt32 = 0
        if _AXUIElementGetWindow(window, &wid) == .success && wid == targetWID {
            return window
        }
    }
    return nil
}

func readFrame(_ window: AXUIElement, wid: UInt32) -> SavedFrame? {
    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else {
        return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return SavedFrame(wid: wid, x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
}

func setPosition(_ window: AXUIElement, x: Double, y: Double) -> Bool {
    var point = CGPoint(x: x, y: y)
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    return err == .success
}

func setSize(_ window: AXUIElement, w: Double, h: Double) -> Bool {
    var size = CGSize(width: w, height: h)
    guard let value = AXValueCreate(.cgSize, &size) else { return false }
    let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    return err == .success
}

func disableEnhancedUI(_ app: AXUIElement) -> Bool {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
    if err == .success, let enabled = value as? Bool, enabled {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        return true
    }
    return false
}

func restoreEnhancedUI(_ app: AXUIElement) {
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

// Read JSON from file argument or stdin
let inputData: Data
if CommandLine.arguments.count > 1 {
    guard let fileData = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
        fputs("Error: could not read \(CommandLine.arguments[1])\n", stderr)
        exit(1)
    }
    inputData = fileData
} else {
    inputData = FileHandle.standardInput.availableData
}

guard let ops = try? JSONDecoder().decode([WindowOp].self, from: inputData), !ops.isEmpty else {
    fputs("Error: expected JSON array of {wid, pid, x, y, w, h} on stdin or file arg\n", stderr)
    exit(1)
}

// Group by PID
var byPID: [Int32: [WindowOp]] = [:]
for op in ops {
    byPID[op.pid, default: []].append(op)
}

// Thread-safe collection for saved frames
let savedLock = NSLock()
var savedFrames: [SavedFrame] = []

// Dispatch per-app work concurrently
let group = DispatchGroup()
let queue = DispatchQueue(label: "winmove", attributes: .concurrent)

for (pid, pidOps) in byPID {
    group.enter()
    queue.async {
        defer { group.leave() }

        let start = DispatchTime.now()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)  // 100ms cap — skip hung apps

        // Skip disableEnhancedUI if all ops are read-only
        let anyMoves = pidOps.contains { $0.read_only != true }
        let wasEnabled = anyMoves ? disableEnhancedUI(app) : false
        defer { if wasEnabled { restoreEnhancedUI(app) } }

        var localSaved: [SavedFrame] = []
        var skipped = 0

        for op in pidOps {
            guard let window = findAXWindow(app: app, targetWID: op.wid) else {
                fputs("warn: window \(op.wid) not found for pid \(pid)\n", stderr)
                skipped += 1
                continue
            }

            // Read-only: just capture frame, no move
            if op.read_only == true {
                if let frame = readFrame(window, wid: op.wid) {
                    localSaved.append(frame)
                }
                continue
            }

            // Save current frame before moving if requested
            if op.save == true {
                if let frame = readFrame(window, wid: op.wid) {
                    localSaved.append(frame)
                }
            }

            let hasSize = op.w > 0 && op.h > 0
            if hasSize {
                // Full frame restore: size, position, size (AeroSpace workaround)
                if !setSize(window, w: op.w, h: op.h) || !setPosition(window, x: op.x, y: op.y) {
                    fputs("warn: AX timeout moving window \(op.wid) pid \(pid)\n", stderr)
                    skipped += 1
                    continue
                }
                _ = setSize(window, w: op.w, h: op.h)
            } else {
                // Position only (parking) — don't touch size
                if !setPosition(window, x: op.x, y: op.y) {
                    fputs("warn: AX timeout parking window \(op.wid) pid \(pid)\n", stderr)
                    skipped += 1
                    continue
                }
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let skipStr = skipped > 0 ? " skipped=\(skipped)" : ""
        fputs("winmove: pid \(pid) \(pidOps.count) ops \(String(format: "%.1f", elapsed))ms\(skipStr)\n", stderr)

        if !localSaved.isEmpty {
            savedLock.lock()
            savedFrames.append(contentsOf: localSaved)
            savedLock.unlock()
        }
    }
}

group.wait()

// Output saved frames as JSON on stdout
if !savedFrames.isEmpty {
    if let jsonData = try? JSONEncoder().encode(savedFrames) {
        FileHandle.standardOutput.write(jsonData)
    }
}
