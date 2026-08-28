import CoreAudio
import Foundation

// Reads only. No default-device setter exists in this experiment.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ code: OSStatus, _ operation: String) throws {
        guard code == noErr else { throw ProbeError("\(operation): OSStatus \(code)") }
    }
    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector, scope: scope)
        try withUnsafeMutablePointer(to: &value) {
            try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0), "read \(selector) on \(id)")
        }
        guard size == MemoryLayout<T>.size else { throw ProbeError("unexpected property size") }
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var property = address(selector)
        try withUnsafeMutablePointer(to: &value) {
            try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0), "read string on \(id)")
        }
        return value as String
    }
    static func list(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var property = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "inventory size")
        guard size <= 16_384, size % 4 == 0 else { throw ProbeError("HAL inventory exceeds bound") }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &values), "inventory")
        return Array(values.prefix(Int(size) / 4))
    }
    static func selfProcess() throws -> AudioObjectID {
        var pid = getpid()
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check(AudioObjectGetPropertyData(system, &property, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id), "resolve SELF")
        if id != 0 {
            let actual = try scalar(id, kAudioProcessPropertyPID, initial: pid_t(0))
            guard actual == pid else { throw ProbeError("HAL identity is not SELF; refusing tap") }
        }
        return id
    }
    static func device(_ id: AudioObjectID) -> [String: Any] {
        guard id != 0 else { return ["id": 0, "state": "not_created"] }
        return ["id": id, "uid": (try? string(id, kAudioDevicePropertyDeviceUID)) ?? "unknown",
                "name": (try? string(id, kAudioObjectPropertyName)) ?? "unknown",
                "alive": (try? scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) as Any? ?? "unknown",
                "running": (try? scalar(id, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(0))) as Any? ?? "unknown"]
    }
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> [String: Any] {
        do { return device(try scalar(system, selector, initial: AudioObjectID(0))) }
        catch { return ["error": String(describing: error)] }
    }
    static func format(_ id: AudioObjectID) -> [String: Any] {
        do {
            let f = try scalar(id, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            return ["sample_rate": f.mSampleRate, "channels": f.mChannelsPerFrame,
                    "format_id": f.mFormatID, "flags": f.mFormatFlags, "bytes_per_frame": f.mBytesPerFrame,
                    "bits_per_channel": f.mBitsPerChannel, "frames_per_packet": f.mFramesPerPacket]
        } catch { return ["state": "unknown", "error": String(describing: error)] }
    }
}
