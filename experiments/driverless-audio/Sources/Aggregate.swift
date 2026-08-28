import Foundation
import CoreAudio

@MainActor
final class AggregateProbe {
    private let allowAudio: Bool
    private let allowCapture: Bool
    private let lock = InstanceLock()
    private var player: TonePlayer?
    private var processID: AudioObjectID = 0
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var tapUID = ""
    private var aggregateUID = ""
    private var phase = "status_only"
    private var deadline: TimeInterval = 0
    private var watchdog: DispatchSourceTimer?
    private var lastError = ""
    var report: (([String: Any]) -> Void)?
    private static let namespace = "ai.openclaw.driverless-audio.aggregate."

    init(arguments: [String]) throws {
        guard arguments.allSatisfy({ ["--allow-audio", "--allow-audio-capture"].contains($0) }) else {
            throw ProbeError("allowed flags: --allow-audio --allow-audio-capture; default status-only")
        }
        allowAudio = arguments.contains("--allow-audio")
        allowCapture = arguments.contains("--allow-audio-capture")
    }

    func status() -> [String: Any] {
        var inventory: [[String: Any]] = []
        var inventoryError = ""
        do {
            for id in try HAL.list(kAudioHardwarePropertyDevices) {
                if let uid = try? HAL.string(id, kAudioDevicePropertyDeviceUID), uid.hasPrefix(Self.namespace) {
                    if inventory.count == 32 { inventoryError = "inventory truncated at 32 matches"; break }
                    inventory.append(HAL.device(id))
                }
            }
        } catch { inventoryError = String(describing: error) }
        let format: [String: Any] = tapID == 0 ? ["state": "not_created"] : HAL.format(tapID)
        var result: [String: Any] = ["lane": "aggregate_input", "bundle_id": "ai.openclaw.driverless-audio.aggregate",
                "pid": getpid(), "hal_process_id": processID, "phase": phase,
                "engine_running": player?.engine.isRunning ?? false, "tone_playing": player?.playing ?? false,
                "tap_id": tapID, "tap_uid": tapUID, "aggregate_uid": aggregateUID,
                "aggregate": HAL.device(aggregateID), "tap_format": format,
                "default_input": HAL.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                "default_output": HAL.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                "matching_inventory_not_ownership": inventory, "inventory_error": inventoryError,
                "last_error": lastError, "diagnostic_reader": false]
        result["launch_consent"] = ["allow_audio": allowAudio, "allow_audio_capture": allowCapture]
        let contract: [String: Any] = ["capture": "SELF output only", "requested_suppression": "muted",
                                     "call_uuid_targeted": false, "changes_default_devices": false]
        result["contract"] = contract
        result["observations"] = ["physical_silence": "unknown", "call_app_opened_input": "unknown", "remote_audibility": "unknown"]
        return result
    }

    func handle(_ command: Command) throws -> [String: Any] {
        switch command.command {
        case "status": break
        case "prepare": try prepare()
        case "start_tone":
            guard allowAudio, allowCapture else { throw ProbeError("relaunch with --allow-audio --allow-audio-capture after operator consent") }
            guard phase == "ready", try healthy() else { throw ProbeError("prepare must reach ready with exact SELF tap/aggregate alive") }
            try player!.play(duration: command.duration ?? 3)
        case "stop_tone": player?.stopTone()
        case "disable":
            guard shutdown() else { throw ProbeError(lastError) }
        default: throw ProbeError("command is not supported by aggregate probe; use prepare")
        }
        return status()
    }

    private func prepare() throws {
        guard allowAudio, allowCapture else { throw ProbeError("prepare requires --allow-audio-capture and --allow-audio; TCC may prompt") }
        guard player == nil, tapID == 0, aggregateID == 0 else { throw ProbeError("already prepared or cleanup incomplete; disable first") }
        try lock.acquire(directory: NSHomeDirectory() + "/Library/Caches/ai.openclaw.driverless-audio", name: "aggregate.lock")
        do {
            // Registration starts only after an output engine exists. Nothing is scheduled yet.
            player = TonePlayer()
            try player!.startSilentEngine()
            phase = "awaiting_self_registration"
            deadline = ProcessInfo.processInfo.systemUptime + 5
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.advance() } }
            timer.resume()
            watchdog = timer
        } catch {
            lastError = String(describing: error)
            _ = shutdown()
            throw error
        }
    }

    private func advance() {
        do {
            if phase == "awaiting_self_registration" {
                processID = try HAL.selfProcess()
                if processID != 0 {
                    let description = CATapDescription(stereoMixdownOfProcesses: [processID])
                    description.name = "OpenClaw Driverless SELF Output Probe"
                    description.isPrivate = false
                    description.muteBehavior = .muted
                    description.uuid = UUID()
                    tapUID = description.uuid.uuidString
                    try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "create SELF output tap")
                    guard tapID != 0, try HAL.string(tapID, kAudioTapPropertyUID) == tapUID else {
                        throw ProbeError("created tap identity mismatch")
                    }
                    aggregateUID = Self.namespace + UUID().uuidString
                    let composition: [String: Any] = [
                        kAudioAggregateDeviceNameKey: "OpenClaw Driverless Input Probe",
                        kAudioAggregateDeviceUIDKey: aggregateUID,
                        kAudioAggregateDeviceIsPrivateKey: false,
                        kAudioAggregateDeviceSubDeviceListKey: [],
                        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
                    ]
                    // No physical subdevice, default selection, auto-start, or capture IOProc.
                    try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "create public input aggregate")
                    guard aggregateID != 0 else { throw ProbeError("HAL returned no aggregate") }
                    phase = "awaiting_aggregate_alive"
                    deadline = ProcessInfo.processInfo.systemUptime + 5
                }
            }
            if phase == "awaiting_aggregate_alive", (try? healthy()) == true {
                phase = "ready"
                report?(status())
            }
            if phase == "ready" {
                guard try healthy() else { throw ProbeError("owned engine/process/tap/aggregate lost; output stopped, no fallback") }
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                throw ProbeError("bounded readiness timeout: \(phase)")
            }
        } catch {
            lastError = String(describing: error)
            _ = shutdown()
            report?(["error": lastError, "phase": phase])
        }
    }

    private func healthy() throws -> Bool {
        guard player?.engine.isRunning == true, processID != 0, tapID != 0, aggregateID != 0 else { return false }
        guard try HAL.selfProcess() == processID,
              try HAL.scalar(processID, kAudioProcessPropertyPID, initial: pid_t(0)) == getpid(),
              try HAL.string(tapID, kAudioTapPropertyUID) == tapUID,
              try HAL.string(aggregateID, kAudioDevicePropertyDeviceUID) == aggregateUID else { return false }
        return try HAL.scalar(aggregateID, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1
    }

    // Only IDs returned to this process are eligible; a namespace match never authorizes deletion.
    private func destroyOwned(id: inout AudioObjectID, uid: String, selector: AudioObjectPropertySelector,
                              list: AudioObjectPropertySelector, destroy: (AudioObjectID) -> OSStatus) throws {
        if id == 0 { return }
        let present = try HAL.list(list).contains(id)
        let currentUID = present ? try HAL.string(id, selector) : nil
        switch RemovalAuthority.evaluate(id: id, expectedUID: uid, present: present, observedUID: currentUID) {
        case .absent: id = 0; return
        case .refuse: throw ProbeError("owned object identity changed; refusing deletion")
        case .owned: break
        }
        try HAL.check(destroy(id), "destroy exact-owned object \(id)")
        for _ in 0..<25 {
            if !(try HAL.list(list)).contains(id) { id = 0; return }
            usleep(20_000)
        }
        throw ProbeError("removal not confirmed; retain UID and use operator-approved manual recovery")
    }

    func shutdown() -> Bool {
        watchdog?.cancel()
        watchdog = nil
        player?.stopTone()
        var failures = [String]()
        do {
            try destroyOwned(id: &aggregateID, uid: aggregateUID, selector: kAudioDevicePropertyDeviceUID,
                             list: kAudioHardwarePropertyDevices, destroy: AudioHardwareDestroyAggregateDevice)
        } catch { failures.append(String(describing: error)) }
        // Keep the tap if aggregate teardown failed; never remove suppression underneath it.
        if aggregateID == 0 {
            do {
                try destroyOwned(id: &tapID, uid: tapUID, selector: kAudioTapPropertyUID,
                                 list: kAudioHardwarePropertyTapList, destroy: AudioHardwareDestroyProcessTap)
            } catch { failures.append(String(describing: error)) }
        }
        player?.shutdown()
        if failures.isEmpty {
            player = nil
            processID = 0
            phase = "stopped"
            lock.release()
        } else {
            phase = "cleanup_failed"
            lastError += " " + failures.joined(separator: "; ")
            report?(["error": lastError, "tap_uid": tapUID, "aggregate_uid": aggregateUID, "manual_recovery_required": true])
        }
        return failures.isEmpty
    }
}

@main
struct AggregateMain {
    @MainActor static func main() {
        do {
            let probe = try AggregateProbe(arguments: Array(CommandLine.arguments.dropFirst()))
            let control = Control(handle: { try probe.handle($0) }, shutdown: { probe.shutdown() })
            probe.report = { [weak control] in control?.emit($0) }
            try control.start(initial: probe.status())
            RunLoop.main.run()
            withExtendedLifetime((probe, control)) {}
        } catch {
            fputs("driverless-audio: \(error)\n", stderr)
            exit(1)
        }
    }
}
