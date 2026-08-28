import UIKit
import AVFAudio

@MainActor
final class InjectionProbe {
    private let allowAudio: Bool
    private let allowPrompt: Bool
    private let session = AVAudioSession.sharedInstance()
    private var player: TonePlayer?
    private var ownsMode = false
    private var permissionPending = false
    private var observers = [NSObjectProtocol]()
    private var watchdog: DispatchSourceTimer?
    var report: (([String: Any]) -> Void)?

    init(arguments: [String]) throws {
        guard arguments.allSatisfy({ ["--allow-audio", "--allow-permission-prompt"].contains($0) }) else {
            throw ProbeError("allowed flags: --allow-audio --allow-permission-prompt; default status-only")
        }
        allowAudio = arguments.contains("--allow-audio")
        allowPrompt = arguments.contains("--allow-permission-prompt")
        for name in [AVAudioSession.microphoneInjectionCapabilitiesChangeNotification,
                     AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Read the non-Sendable notification before entering actor isolation.
                let loss = note.name != AVAudioSession.microphoneInjectionCapabilitiesChangeNotification ||
                    (note.userInfo?[AVAudioSessionMicrophoneInjectionIsAvailableKey] as? Bool != true)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A loss notification disarms even if a subsequent property read has recovered.
                    if loss || !self.gate.canPlay { self.disarm() }
                    self.report?(self.status())
                }
            })
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.ownsMode && !self.gate.canPlay { self.disarm() }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private var permission: String {
        switch AVAudioApplication.shared.microphoneInjectionPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        case .serviceDisabled: return "service_disabled"
        @unknown default: return "unknown"
        }
    }
    private var gate: InjectionGate {
        InjectionGate(allowAudio: allowAudio, granted: permission == "granted",
                      available: session.isMicrophoneInjectionAvailable,
                      enabled: ownsMode && session.preferredMicrophoneInjectionMode == .spokenAudio)
    }

    func status() -> [String: Any] {
        ["lane": "catalyst_injection", "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
         "pid": ProcessInfo.processInfo.processIdentifier, "permission": permission,
         "permission_pending": permissionPending,
         "preferred_mode_raw": session.preferredMicrophoneInjectionMode.rawValue,
         "available": session.isMicrophoneInjectionAvailable, "owns_mode": ownsMode,
         "engine_running": player?.engine.isRunning ?? false, "tone_playing": player?.playing ?? false,
         "launch_consent": ["allow_audio": allowAudio, "allow_permission_prompt": allowPrompt],
         "contract": ["local_playback": true, "mixes_with_microphone": true, "follows_call_mute": true,
                      "call_uuid_targeted": false, "purpose": "AAC synthesized speech; tone is diagnostic only"],
         "observations": ["remote_audibility": "unknown", "intended_call_routing": "unknown"]]
    }

    func handle(_ command: Command) throws -> [String: Any] {
        switch command.command {
        case "status": break
        case "request_permission":
            guard allowPrompt else { throw ProbeError("relaunch with --allow-permission-prompt after explicit operator consent") }
            guard !permissionPending else { throw ProbeError("permission request already pending") }
            permissionPending = true
            AVAudioApplication.requestMicrophoneInjectionPermission { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionPending = false
                    self.report?(self.status())
                }
            }
        case "enable":
            guard allowAudio, permission == "granted", session.isMicrophoneInjectionAvailable else {
                throw ProbeError("enable requires --allow-audio, granted injection permission and an available compatible call")
            }
            try session.setPreferredMicrophoneInjectionMode(.spokenAudio)
            ownsMode = true
            guard gate.canPlay else { disarm(); throw ProbeError("system did not enable preferred mode") }
        case "start_tone":
            guard gate.canPlay else { disarm(); throw ProbeError("start requires consent, granted permission, compatible call and enable") }
            do {
                if player == nil { player = TonePlayer() }
                try player!.startSilentEngine()
                guard gate.canPlay else { throw ProbeError("capability lost before playback") }
                try player!.play(duration: command.duration ?? 3)
            } catch { disarm(); throw error }
        case "stop_tone": player?.stopTone()
        case "disable":
            player?.shutdown()
            if ownsMode { try session.setPreferredMicrophoneInjectionMode(.none); ownsMode = false }
        default: throw ProbeError("command is not supported by Catalyst")
        }
        return status()
    }

    private func disarm() {
        player?.shutdown()
        if ownsMode {
            do { try session.setPreferredMicrophoneInjectionMode(.none); ownsMode = false }
            catch { report?(["error": "owned injection mode could not be disabled: \(error)"]) }
        }
    }

    func shutdown() -> Bool {
        watchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        disarm()
        return !ownsMode
    }
}

@main
@MainActor
final class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var probe: InjectionProbe?
    private var control: Control?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        do {
            let probe = try InjectionProbe(arguments: Array(CommandLine.arguments.dropFirst()))
            let control = Control(handle: { try probe.handle($0) }, shutdown: { probe.shutdown() })
            probe.report = { [weak control] in control?.emit($0) }
            self.probe = probe
            self.control = control
            let view = UIViewController()
            let label = UILabel()
            label.text = "Driverless Audio Probe\nStatus-only on launch. Control via bounded stdin JSONL.\nNo live FaceTime proof."
            label.numberOfLines = 0
            label.textAlignment = .center
            view.view = label
            window = UIWindow(frame: UIScreen.main.bounds)
            window?.rootViewController = view
            window?.makeKeyAndVisible()
            try control.start(initial: probe.status())
            return true
        } catch {
            fputs("driverless-audio: \(error)\n", stderr)
            exit(1)
        }
    }
    func applicationWillTerminate(_ application: UIApplication) { _ = probe?.shutdown() }
}
