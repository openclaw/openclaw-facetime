import Foundation
import CoreFoundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Command: Decodable {
    let command: String
    let duration: Double?

    static func parse(_ data: Data) throws -> Command {
        guard data.count <= 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["command", "duration"]),
              let name = object["command"] as? String,
              ["status", "request_permission", "enable", "prepare", "start_tone", "stop_tone", "disable", "quit"].contains(name)
        else { throw ProbeError("expected one JSON object, known command, max 1024 bytes") }
        if object.keys.contains("duration") {
            guard name == "start_tone", let n = object["duration"] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= 0.03, n.doubleValue <= 10
            else { throw ProbeError("duration is allowed only for start_tone: 0.03...10 seconds") }
        }
        return try JSONDecoder().decode(Command.self, from: data)
    }
}

// The finite buffer, not a callback or timer, is the hard duration bound.
enum Tone {
    static let rate = 48_000.0
    static let amplitude = 0.08
    static let frequencies = [440.0, 660.0, 880.0]

    static func samples(duration: Double) throws -> [Float] {
        guard duration.isFinite, (0.03...10).contains(duration) else {
            throw ProbeError("tone duration must be 0.03...10 seconds")
        }
        let count = Int(duration * rate)
        return (0..<count).map { frame in
            let segment = min(2, frame * 3 / count)
            let start = (segment * count + 2) / 3
            let end = ((segment + 1) * count + 2) / 3
            let envelope = min(1.0, Double(min(frame - start, end - 1 - frame)) / 240.0)
            return Float(amplitude * max(0, envelope) * sin(2 * .pi * frequencies[segment] * Double(frame - start) / rate))
        }
    }
}

struct InjectionGate {
    var allowAudio = false
    var granted = false
    var available = false
    var enabled = false
    var canPlay: Bool { allowAudio && granted && available && enabled }
}

struct PlaybackGeneration {
    private(set) var value: UInt64 = 0
    mutating func invalidate() { value &+= 1 }
    func accepts(_ completion: UInt64) -> Bool { value == completion }
}

enum RemovalAuthority {
    case absent, owned, refuse
    static func evaluate(id: UInt32, expectedUID: String, present: Bool, observedUID: String?) -> Self {
        if !present || id == 0 { return .absent }
        return !expectedUID.isEmpty && observedUID == expectedUID ? .owned : .refuse
    }
}

struct LineFrames {
    private var bytes = Data()
    mutating func append(_ incoming: Data) throws -> [Data] {
        var result = [Data]()
        for byte in incoming {
            if byte == 10 {
                guard !bytes.isEmpty else { throw ProbeError("empty frame") }
                result.append(bytes)
                bytes.removeAll(keepingCapacity: true)
                guard result.count <= 16 else { throw ProbeError("too many frames in one read") }
            } else {
                guard bytes.count < 1024 else { throw ProbeError("frame exceeds 1024 bytes") }
                bytes.append(byte)
            }
        }
        return result
    }
    var hasPartialFrame: Bool { !bytes.isEmpty }
}
