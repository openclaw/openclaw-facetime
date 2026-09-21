@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation

private let outputSampleRate = 24_000.0
/* OPENCLAW_ERRORS */
/* OPENCLAW_WRITER_AND_LIFECYCLE */

// No audio devices or Apple processes are touched. PCM conversion, pipe writes,
// failure dispatch, owner setup, lifecycle and the final wait loop are production code.
private final class ProcessTap: CarrierSuppressionTap {
  var stopped = false
  init(processObjectIDs: [AudioObjectID], lifecycle: CaptureLifecycle) throws {
    precondition(signalSources[SIGINT]?.handler != nil && signalSources[SIGTERM]?.handler != nil,
                 "termination handling must exist before the first tap starts")
    // This check process is task-created. The production signal-interception
    // calls must make a real startup SIGTERM non-destructive.
    Darwin.raise(SIGTERM)
    signalSources[SIGTERM]?.handler?()
    precondition(!lifecycle.state().stopping, "startup signal bypassed control intent")
    fixture.taps.append(self)
  }
  func start() throws {}
  func stop() { self.stopped = true }
}
private final class Fixture: @unchecked Sendable {
  let lifecycle = CaptureLifecycle()
  var owner: CaptureCarrierOwner!
  var active: AudioProcess? = AudioProcess(
    bundleID: "com.apple.FaceTime", name: "FaceTime", objectID: 101,
    identity: CapturedProcessIdentity(pid: 101, uniqueID: 101, version: 1), runningOutput: true, trustedIdentity: "com.apple.FaceTime")
  var taps: [ProcessTap] = []
  var settleAttempts = 0
  var retryTicks = 0
  var allowSettlement = false
  var writer: PCMWriter!
  var control: Pipe!
  var monitorHandoff = false
  var monitorTicks = 0
}
private var fixture: Fixture!

private func discoverActiveOwner(requestedNames: Set<String>, requireCompleteSnapshot: Bool) throws -> AudioProcess? {
  precondition(requireCompleteSnapshot)
  return fixture.active
}
private func startProcessTap(_ process: AudioProcess, lifecycle: CaptureLifecycle) throws -> ProcessTap {
  try ProcessTap(processObjectIDs: [process.objectID], lifecycle: lifecycle)
}
private final class NativePlayback {
  func enqueue(_ audio: Data) { preconditionFailure("unexpected playback") }
  func markDrain(generation: UInt32) { preconditionFailure("unexpected playback") }
  func clear(generation: UInt32) { preconditionFailure("unexpected playback") }
}
/* OPENCLAW_PARENT_READER */
private func settleCapturedCarrier(_ process: AudioProcess) -> Bool {
  fixture.settleAttempts += 1
  precondition(fixture.taps.allSatisfy { !$0.stopped }, "settlement must precede tap release")
  if !fixture.allowSettlement { return false }
  fixture.active = nil
  return true
}
@discardableResult
private func usleep(_ duration: UInt32) -> Int32 {
  // Advance the retry boundary deterministically, without sleeping or polling.
  fixture.retryTicks += 1
  precondition(!fixture.lifecycle.state().stopping, "failed settlement published stopping")
  if fixture.retryTicks == 1 {
    precondition(fixture.taps.allSatisfy { !$0.stopped }, "failed settlement released suppression")
    precondition(!fixture.owner.stopCaptures(), "cleanup overrode unsettled ownership")
    let attempts = fixture.settleAttempts
    fixture.lifecycle.handleUnexpectedParentEOF()
    fixture.lifecycle.requestStop()
    precondition(fixture.settleAttempts == attempts, "concurrent EOF started duplicate settlement")
    precondition(!fixture.lifecycle.state().stopping, "concurrent stop escaped settlement")
    fixture.allowSettlement = true
  } else {
    precondition(fixture.retryTicks <= 13, "shutdown did not converge")
  }
  ContinuousClock.advance(by: .milliseconds(250))
  return 0
}

private final class WriterCallbackFixture {
  var writer: PCMWriter!
  init(format: AVAudioFormat, lifecycle: CaptureLifecycle) throws {
    let streamDescription = format.streamDescription.pointee
/* OPENCLAW_PCM_CALLBACK */
  }
}

// Drive signal delivery and handoffs deterministically; no Apple process or
// audio device is signaled or accessed by this fixture.
private let SIG_IGN: Int32 = 0
private func signal(_ value: Int32, _ handler: Int32) { _ = Darwin.signal(value, Darwin.SIG_IGN) }
private protocol DispatchSourceSignal: AnyObject {
  func cancel()
}
private final class SyntheticSignal: DispatchSourceSignal {
  var handler: (() -> Void)?
  func setEventHandler(_ handler: @escaping () -> Void) { self.handler = handler }
  func resume() {}
  func cancel() {}
}
private var signalSources: [Int32: SyntheticSignal] = [:]
private enum DispatchSource {
  static func makeSignalSource(signal: Int32, queue: DispatchQueue) -> SyntheticSignal {
    let source = SyntheticSignal()
    signalSources[signal] = source
    return source
  }
  static func makeUserDataAddSource(queue: DispatchQueue) -> any DispatchSourceUserDataAdd {
    Dispatch.DispatchSource.makeUserDataAddSource(queue: queue)
  }
}
private func drainParentControl(_ lifecycle: CaptureLifecycle) async {
  await withCheckedContinuation { continuation in
    let reader = ParentCommandReader(markCloseSafe: { lifecycle.markCloseSafe() }) {
      lifecycle.handleUnexpectedParentEOF()
      continuation.resume()
    }
    reader.start()
  }
}
private enum Task {
  static func sleep(for duration: Duration) async throws {
    precondition(fixture.monitorHandoff, "settled wait loop failed to exit")
    fixture.monitorTicks += 1
    if fixture.monitorTicks == 1 {
      fixture.active = AudioProcess(
        bundleID: "com.apple.avconferenced", name: "avconferenced", objectID: 102,
        identity: CapturedProcessIdentity(pid: 102, uniqueID: 102, version: 1),
        runningOutput: true, trustedIdentity: "com.apple.avconferenced")
      ContinuousClock.advance(by: .milliseconds(250))
    } else {
      precondition(fixture.monitorTicks == 2 && fixture.taps.count == 2,
                   "stdout failure disabled successor suppression while control remained open")
      precondition(fixture.taps.allSatisfy { !$0.stopped } && fixture.settleAttempts == 0)
      try fixture.control.fileHandleForWriting.write(contentsOf: Data([4, 0, 0, 0, 4, 0, 0, 0, 0]))
      try fixture.control.fileHandleForWriting.close()
      await drainParentControl(fixture.lifecycle)
    }
  }
}
private enum OpenClawInputRoutePhase { case steadyState }
private enum RouteDecision: Equatable { case ready, retry, fail([String]) }
private func resolveActiveOwner(requestedNames: Set<String>) throws -> AudioProcess {
  guard let active = fixture.active else { throw CaptureError.audioOwnerChanged("synthetic") }
  return active
}
private func waitForActiveOwner(requestedNames: Set<String>, processNames: [String], timeout: Duration) async throws -> AudioProcess { throw CaptureError.audioOwnerChanged("synthetic") }
private func waitForOpenClawRoutes(_ process: AudioProcess, requestedNames: Set<String>, phase: OpenClawInputRoutePhase) async throws { preconditionFailure("unexpected route query") }
private func outputRouteDevices(_ process: AudioProcess) throws -> [String] { preconditionFailure("unexpected route query") }
private func inputDeviceNames(_ process: AudioProcess) throws -> [String] { preconditionFailure("unexpected route query") }
private func decideOpenClawOutputRoute(_ devices: [String]) -> RouteDecision { preconditionFailure("unexpected route query") }
private func decideOpenClawInputRoute(_ devices: [String], phase: OpenClawInputRoutePhase) -> RouteDecision { preconditionFailure("unexpected route query") }
/* OPENCLAW_WAIT_LOOP */

@main
private struct CapturePipeLossChecks {
  static func main() async throws {
    CaptureStandardOutput.ignoreBrokenPipeSignal()
    for scenario in 0..<3 {
      let safeClose = scenario != 0
      signalSources.removeAll()
      fixture = Fixture()
      ContinuousClock.now = .init(offset: .zero)
      fixture.monitorHandoff = scenario == 2
      let lifecycle = fixture.lifecycle
      let selected = [fixture.active!]
      let currentProcess = selected[0]
      let requestedNames: Set<String> = ["facetime"]
/* OPENCLAW_OWNER_SETUP */
      fixture.owner = ownerRef
      lifecycle.requestStop()
      precondition(!lifecycle.state().stopping, "signal cannot release suppression before control intent")
      let control = Pipe()
      fixture.control = control
      let savedStdin = dup(STDIN_FILENO)
      precondition(savedStdin >= 0 && dup2(control.fileHandleForReading.fileDescriptor, STDIN_FILENO) >= 0)
      if safeClose && !fixture.monitorHandoff {
        // Queue the real marker before stdout closes, but delay the control
        // reader to reproduce the cross-pipe scheduling race deterministically.
        try control.fileHandleForWriting.write(contentsOf: Data([4, 0, 0, 0, 4, 0, 0, 0, 0]))
      }
      if !fixture.monitorHandoff { try control.fileHandleForWriting.close() }
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
      let callback = try WriterCallbackFixture(format: format, lifecycle: lifecycle)
      fixture.writer = callback.writer
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      input.frameLength = 1024
      input.floatChannelData![0].initialize(repeating: 0, count: 1024)
      let pipe = Pipe()
      try pipe.fileHandleForReading.close()
      let savedStdout = dup(STDOUT_FILENO)
      precondition(savedStdout >= 0 && dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0)
      // Drain on the real dedicated PCM queue; completion runs after its failure callback.
      precondition(callback.writer.enqueue(input.audioBufferList))
      await withCheckedContinuation { continuation in
        callback.writer.finishFixtureDrain { continuation.resume() }
      }
      precondition(dup2(savedStdout, STDOUT_FILENO) >= 0)
      close(savedStdout)
      try pipe.fileHandleForWriting.close()
      precondition(lifecycle.state().failure != nil && !lifecycle.state().stopping)
      lifecycle.requestStop()
      precondition(!lifecycle.state().stopping, "signal cannot overtake a queued safe-close marker")
      precondition(fixture.settleAttempts == 0 && fixture.taps.allSatisfy { !$0.stopped },
                   "stdout failure must not overtake queued control intent")
      if fixture.monitorHandoff {
        try await waitForTerminationSignal(lifecycle, process: selected[0], requestedNames: requestedNames, ownerRef: ownerRef)
      } else {
        await drainParentControl(lifecycle)
      }
      precondition(dup2(savedStdin, STDIN_FILENO) >= 0)
      close(savedStdin)
      try control.fileHandleForReading.close()
      precondition(lifecycle.state().stopping)
      precondition(fixture.settleAttempts == (safeClose ? 0 : 2))
      precondition(fixture.retryTicks == (safeClose ? 0 : 13))
      precondition(fixture.taps.allSatisfy { $0.stopped == (!safeClose || fixture.monitorHandoff) })
      try await waitForTerminationSignal(lifecycle, process: selected[0], requestedNames: requestedNames, ownerRef: ownerRef)
      precondition(fixture.taps.allSatisfy(\.stopped))
    }
    fputs("PASS: real PCM pipe loss retains suppression through failed settlement and honors safe-close\n", stderr)
  }
}

// This same-file test extension can join the private queue without a production seam.
private extension PCMWriter {
  func finishFixtureDrain(_ completion: @escaping @Sendable () -> Void) {
    self.worker.async { self.drainPending(); completion() }
  }
}
