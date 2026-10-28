// SPDX-License-Identifier: GPL-3.0-only
// Run with: swift scripts/diagnose-g9n9n-hid.swift [seconds] [--poll]
// Uses public, non-exclusive HID monitoring. Never injects events or changes reports.
import Foundation
import IOKit.hid

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func record(_ message: String) {
    print("\(formatter.string(from: Date())) \(message)")
    fflush(stdout)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let positional = arguments.filter { $0 != "--poll" }
guard positional.count <= 1,
      let duration = positional.first.map({ Double($0) }) ?? 300,
      duration.isFinite, duration > 0, duration <= 3600 else {
    record("ERROR usage: swift scripts/diagnose-g9n9n-hid.swift [seconds: 0 < n <= 3600] [--poll]")
    exit(2)
}
let pollsInput = arguments.contains("--poll")
var reportCount = 0
var valueCount = 0
var matchedCount = 0
var pollCount = 0
var pollDevice: IOHIDDevice?
var previousPoll: String?
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: 0x18d1,
    kIOHIDProductIDKey: 0x9450,
] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, result, _, device in
    matchedCount += 1
    // Do not silently choose a unit when multiple matching remotes are present.
    pollDevice = matchedCount == 1 ? device : nil
    let maximum = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
    let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
    let hex = descriptor?.map { String(format: "%02x", $0) }.joined() ?? "unavailable"
    record("MATCH result=\(result) max_input_bytes=\(maximum.map { String(describing: $0) } ?? "unknown") descriptor=\(hex)")
}, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, result, _, _ in
    pollDevice = nil
    record("REMOVED result=\(result)")
}, nil)
IOHIDManagerRegisterInputReportCallback(manager, { _, result, _, type, reportID, bytes, length in
    reportCount += 1
    // Only retain the three-byte Consumer Control report under investigation.
    // Matching VID/PID alone does not make other vendor reports safe to archive.
    let payload = type == kIOHIDReportTypeInput && reportID == 1 && length <= 3
        ? UnsafeBufferPointer(start: bytes, count: max(0, length))
            .map { String(format: "%02x", $0) }.joined(separator: " ")
        : "omitted"
    record("REPORT result=\(result) type=\(type.rawValue) id=\(reportID) bytes=\(length) payload=\(payload)")
}, nil)
IOHIDManagerRegisterInputValueCallback(manager, { _, result, _, value in
    valueCount += 1
    let element = IOHIDValueGetElement(value)
    record("VALUE result=\(result) id=\(IOHIDElementGetReportID(element)) page=\(IOHIDElementGetUsagePage(element)) usage=\(IOHIDElementGetUsage(element)) value=\(IOHIDValueGetIntegerValue(value))")
}, nil)
let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
record("ACCESS listen=\(access.rawValue) granted=\(access == kIOHIDAccessTypeGranted)")
guard access == kIOHIDAccessTypeGranted else {
    record("ERROR input_monitoring_not_granted; no-input results would be inconclusive")
    exit(1)
}
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
record("OPEN result=\(result) exclusive=false")
guard result == kIOReturnSuccess else {
    if result == kIOReturnExclusiveAccess {
        record("ERROR exclusive_access; quit Voice Input Buddy and other device owners before capturing")
    }
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    exit(1)
}
var pollTimer: Timer?
if pollsInput {
    record("POLL enabled interval_ms=200; empty successful reads do not prove key state")
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        guard let device = pollDevice else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 1
        var length = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 1, &bytes, &length)
        pollCount += 1
        let payload = bytes.prefix(max(0, min(length, bytes.count)))
            .map { String(format: "%02x", $0) }.joined(separator: " ")
        let state = "result=\(result) bytes=\(length) payload=\(payload)"
        if state != previousPoll {
            record("POLL \(state)")
            previousPoll = state
        }
    }
}
record("CAPTURE seconds=\(duration) only_vid=18d1 only_pid=9450 poll=\(pollsInput)")
CFRunLoopRunInMode(.defaultMode, duration, false)
pollTimer?.invalidate()
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
record("SUMMARY matches=\(matchedCount) reports=\(reportCount) values=\(valueCount) polls=\(pollCount)")
if matchedCount == 0 { record("INCONCLUSIVE no_matching_device"); exit(1) }
