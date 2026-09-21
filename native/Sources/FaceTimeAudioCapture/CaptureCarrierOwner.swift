import CoreAudio
import Foundation

let carrierHandoffGracePeriod: Duration = .seconds(3)

struct AudioProcess: Sendable {
  let bundleID: String
  let name: String
  let objectID: AudioObjectID
  let identity: CapturedProcessIdentity
  let runningOutput: Bool
  let trustedIdentity: String

  var pid: pid_t { self.identity.pid }

  func hasSameIdentity(as other: AudioProcess) -> Bool {
    self.identity == other.identity && self.objectID == other.objectID
      && self.trustedIdentity == other.trustedIdentity
  }
}

protocol CarrierSuppressionTap: AnyObject {
  func stop()
}

enum CaptureCarrierOwnerError: LocalizedError {
  case shuttingDown
  case terminationUnconfirmed

  var errorDescription: String? {
    switch self {
    case .shuttingDown:
      return "FaceTime capture is shutting down and cannot accept another carrier."
    case .terminationUnconfirmed:
      return "The captured FaceTime carrier could not be confirmed stopped; audio suppression is retained."
    }
  }
}

final class CaptureCarrierOwner: @unchecked Sendable {
  private struct Carrier {
    let process: AudioProcess
    var tap: (any CarrierSuppressionTap)?
    var settled = false
  }

  private let lock = NSLock()
  private let discoverCurrent: () throws -> AudioProcess?
  private let startCapture: (AudioProcess) throws -> any CarrierSuppressionTap
  private let settleCarrier: (AudioProcess) -> Bool
  private var carriers: [Carrier] = []
  private var shuttingDown = false
  private var absenceSince: ContinuousClock.Instant?
  private var shutdownConfirmed = false

  init(
    discoverCurrent: @escaping () throws -> AudioProcess?,
    startCapture: @escaping (AudioProcess) throws -> any CarrierSuppressionTap,
    settleCarrier: @escaping (AudioProcess) -> Bool
  ) {
    self.discoverCurrent = discoverCurrent
    self.startCapture = startCapture
    self.settleCarrier = settleCarrier
  }

  func capture(_ carrier: AudioProcess) throws {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.shuttingDown else {
      throw CaptureCarrierOwnerError.shuttingDown
    }
    try self.secure(carrier)
  }

  func finishHandoff(_ carrier: AudioProcess) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.shuttingDown,
      let retained = self.carriers.first(where: { $0.process.hasSameIdentity(as: carrier) }),
      retained.tap != nil
    else { return false }
    for previous in self.carriers where !previous.process.hasSameIdentity(as: carrier) {
      previous.tap?.stop()
    }
    self.carriers = [retained]
    return true
  }

  func shutdownStep() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.shuttingDown = true
    if self.shutdownConfirmed { return true }
    var discoveryComplete = true
    do {
      if let current = try self.discoverCurrent() {
        // A successor can become active before the normal monitor registers it.
        // Own its suppression resource before attempting any termination.
        try self.secure(current)
      }
    } catch {
      discoveryComplete = false
    }
    for index in self.carriers.indices {
      self.carriers[index].settled = self.settleCarrier(self.carriers[index].process)
    }
    var activeOwnerAbsent = false
    do {
      if let current = try self.discoverCurrent() {
        // A handoff can also happen during termination. Secure that successor
        // now; the next step will settle it without dropping its suppression.
        try self.secure(current)
      } else {
        activeOwnerAbsent = true
      }
    } catch {
      discoveryComplete = false
    }
    self.carriers.removeAll { carrier in
      guard carrier.settled else { return false }
      carrier.tap?.stop()
      return true
    }
    if discoveryComplete && activeOwnerAbsent && self.carriers.isEmpty {
      let now = ContinuousClock.now
      if let absenceSince = self.absenceSince {
        self.shutdownConfirmed = absenceSince.duration(to: now) >= carrierHandoffGracePeriod
      } else {
        self.absenceSince = now
      }
    } else {
      self.absenceSince = nil
    }
    return self.shutdownConfirmed
  }

  @discardableResult
  func stopCaptures() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.shuttingDown || self.shutdownConfirmed else { return false }
    self.shuttingDown = true
    self.shutdownConfirmed = true
    for carrier in self.carriers {
      carrier.tap?.stop()
    }
    self.carriers.removeAll()
    return true
  }

  private func secure(_ process: AudioProcess) throws {
    self.absenceSince = nil
    let index: Int
    if let existing = self.carriers.firstIndex(where: { $0.process.hasSameIdentity(as: process) }) {
      index = existing
    } else {
      index = self.carriers.count
      self.carriers.append(Carrier(process: process))
    }
    self.carriers[index].settled = false
    if self.carriers[index].tap == nil {
      self.carriers[index].tap = try self.startCapture(process)
    }
  }
}
