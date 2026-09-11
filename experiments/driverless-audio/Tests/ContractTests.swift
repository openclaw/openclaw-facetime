import Foundation

@main
struct ContractTests {
    static func main() throws {
        func rejected(_ text: String) -> Bool { (try? Command.parse(Data(text.utf8))) == nil }
        precondition(rejected("{\"command\":\"start_tone\",\"duration\":11}"))
        precondition(rejected("{\"command\":\"start_tone\",\"duration\":true}"))
        precondition(rejected("{\"command\":\"status\",\"duration\":1}"))
        precondition(rejected("{\"command\":\"status\",\"extra\":0}"))
        precondition(rejected("{\"command\":\"status\"}" + String(repeating: " ", count: 1024)))
        precondition(rejected("{\"command\":\"capture_microphone\"}"))
        let command = try Command.parse(Data("{\"command\":\"start_tone\",\"duration\":10}".utf8))
        let tone = try Tone.samples(duration: command.duration!)
        let repeated = try Tone.samples(duration: 10)
        precondition(tone == repeated && tone.count == 480_000)
        precondition(tone.allSatisfy { abs($0) <= Float(Tone.amplitude) })
        precondition((try? Tone.samples(duration: .infinity)) == nil)
        precondition((try? Tone.samples(duration: .nan)) == nil)
        precondition((try? Tone.samples(duration: 10.001)) == nil)
        // Count positive zero crossings well inside each segment, independently of the synthesis formula.
        let short = try Tone.samples(duration: 3)
        for (index, frequency) in [440, 660, 880].enumerated() {
            let start = index * 48_000 + 4_800
            let end = start + 24_000
            let crossings = (start..<end).filter { short[$0] <= 0 && short[$0 + 1] > 0 }.count
            precondition(abs(crossings - frequency / 2) <= 1)
        }
        for bits in 0..<16 {
            let gate = InjectionGate(allowAudio: bits & 1 != 0, granted: bits & 2 != 0,
                                     available: bits & 4 != 0, enabled: bits & 8 != 0)
            precondition(gate.canPlay == (bits == 15))
        }
        var gate = InjectionGate(allowAudio: true, granted: true, available: true, enabled: true)
        gate.available = false
        precondition(!gate.canPlay)
        gate.available = true
        gate.granted = false
        precondition(!gate.canPlay)
        var generation = PlaybackGeneration()
        let old = generation.value
        generation.invalidate()
        precondition(!generation.accepts(old) && generation.accepts(generation.value))
        var frames = LineFrames()
        let partial = try frames.append(Data("{\"command\":".utf8))
        precondition(partial.isEmpty)
        let parsed = try frames.append(Data("\"status\"}\n".utf8))
        precondition(parsed.count == 1 && !frames.hasPartialFrame)
        var overflow = LineFrames()
        precondition((try? overflow.append(Data(repeating: 32, count: 1025))) == nil)
        var flood = LineFrames()
        precondition((try? flood.append(Data(String(repeating: "x\n", count: 17).utf8))) == nil)
        precondition(RemovalAuthority.evaluate(id: 12, expectedUID: "run.a", present: true, observedUID: "run.a") == .owned)
        precondition(RemovalAuthority.evaluate(id: 12, expectedUID: "run.a", present: true, observedUID: "run.b") == .refuse)
        precondition(RemovalAuthority.evaluate(id: 12, expectedUID: "run.a", present: true, observedUID: nil) == .refuse)
        precondition(RemovalAuthority.evaluate(id: 12, expectedUID: "run.a", present: false, observedUID: nil) == .absent)
        print("ContractTests: protocol bounds, tone determinism/caps, permission/capability gates, stale completion, exact-owned cleanup passed")
    }
}
