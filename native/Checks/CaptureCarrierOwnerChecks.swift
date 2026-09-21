import Foundation

@main
struct CaptureCarrierOwnerChecks {
  static func main() throws {
    try preRegistrationSuccessorIsSecured()
    try successorDuringTerminationIsSecured()
    try successorBetweenAbsenceSnapshotsRestartsVerification()
    try failedSignalRetainsTheNewTap()
    try failedTapStillAttemptsExactSettlement()
    try transientDiscoveryRecovers()
    try normalHandoffRetiresTheOldTap()
    try reusedPIDAcquiresItsOwnSuppression()
    try delayedSuccessorRestartsTheQuietInterval()
  }

  private static func preRegistrationSuccessorIsSecured() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.active = carrier(102)
    fixture.events.removeAll()
    expect(!step(owner), "shutdown requires the complete quiet handoff interval")
    expect(fixture.events.prefix(3) == ["capture:102", "settle:101", "settle:102"],
           "EOF secures the unregistered successor before terminating any carrier")
    expect(step(owner), "the complete quiet handoff interval settle shutdown")
    do {
      try owner.capture(carrier(103))
      expect(false, "shutdown admitted a late capture")
    } catch CaptureCarrierOwnerError.shuttingDown {
      expect(fixture.taps[103] == nil, "late capture has no native side effects")
    }
  }

  private static func successorDuringTerminationIsSecured() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.successorAfterSettlement = carrier(102)
    expect(!step(owner), "a successor prevents premature shutdown")
    expect(fixture.taps[102]?.stopped == false,
           "post-termination discovery immediately owns the successor's suppression")
    expect(!fixture.events.contains("settle:102"), "the newly secured successor waits for the next step")
    expect(!step(owner), "settling the successor starts a new absence sequence")
    expect(step(owner), "successor settlement is followed by stable absence")
    expect(fixture.taps.values.allSatisfy(\.stopped), "confirmed carriers release their taps")
  }

  private static func failedSignalRetainsTheNewTap() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.active = carrier(102)
    fixture.unconfirmed = [102]
    expect(!step(owner), "failed termination cannot complete shutdown")
    expect(fixture.taps[102]?.stopped == false, "failed termination retains the emergency tap")
    expect(fixture.taps[101]?.stopped == true, "settled resources are pruned while uncertainty remains")
    expect(!owner.stopCaptures(), "cleanup cannot force-release an uncertain tap")
    expect(!owner.finishHandoff(carrier(102)), "late route verification cannot retire shutdown taps")
    expect(fixture.taps[102]?.stopped == false, "the successor remains suppressed")
    fixture.unconfirmed.remove(102)
    expect(!step(owner), "a later successful signal starts absence verification")
    expect(step(owner), "termination retries recover without another EOF")
  }

  private static func successorBetweenAbsenceSnapshotsRestartsVerification() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    expect(!step(owner), "the first empty snapshot is not stable absence")
    fixture.active = carrier(102)
    expect(!step(owner), "an intervening successor resets absence verification")
    expect(step(owner), "the successor requires a new quiet handoff interval")
  }

  private static func failedTapStillAttemptsExactSettlement() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.active = carrier(102)
    fixture.unavailableTaps = [102]
    fixture.unconfirmed = [101, 102]
    fixture.events.removeAll()
    expect(!step(owner), "failed suppression and settlement remain unconfirmed")
    expect(fixture.events.prefix(3) == ["capture:102", "settle:101", "settle:102"],
           "failed tap acquisition still attempts exact authorized settlement immediately")
    expect(fixture.events.filter { $0.hasPrefix("settle:") } == ["settle:101", "settle:102"],
           "tap failure does not broaden the identities selected for termination")
    expect(fixture.taps[102] == nil, "the failed emergency tap is not reported as suppression")
    expect(fixture.taps[101]?.stopped == false, "existing uncertain suppression stays retained")
    expect(!owner.stopCaptures(), "cleanup cannot release existing uncertain suppression")
    fixture.unavailableTaps.remove(102)
    fixture.unconfirmed.removeAll()
    expect(!step(owner), "the next step retries capture and settles the exact carriers")
    expect(fixture.taps[102]?.stopped == true, "recovered capture is released only after settlement")
    expect(step(owner), "recovery completes after the complete quiet handoff interval")
  }

  private static func transientDiscoveryRecovers() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.discoveryFailures = 1
    fixture.unconfirmed = [101]
    expect(!step(owner), "failed discovery is never an empty snapshot")
    expect(fixture.taps[101]?.stopped == false, "failed discovery retains an unsettled capture")
    fixture.unconfirmed.remove(101)
    expect(!step(owner), "a successful retry starts fresh absence verification")
    expect(step(owner), "transient discovery failure does not strand shutdown")
  }

  private static func normalHandoffRetiresTheOldTap() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    try owner.capture(carrier(102))
    expect(owner.finishHandoff(carrier(102)), "route verification completes a normal handoff")
    expect(fixture.taps[101]?.stopped == true, "a verified handoff releases the obsolete tap")
    expect(fixture.taps[102]?.stopped == false, "the active tap stays owned")
    expect(owner.stopCaptures(), "ordinary proven-close cleanup succeeds")
    expect(fixture.taps[102]?.stopped == true, "cleanup releases the active tap")
    expect(!fixture.events.contains(where: { $0.hasPrefix("settle:") }),
           "ordinary cleanup does not terminate a carrier")
  }

  private static func reusedPIDAcquiresItsOwnSuppression() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    fixture.events.removeAll()
    fixture.active = carrier(101, version: 2)
    expect(!step(owner), "a replacement generation must restart absence verification")
    expect(fixture.events == ["capture:101", "settle:101", "settle:101"],
           "same numeric PID with a new generation needs separate suppression and settlement")
    expect(step(owner), "both generations must settle before shutdown completes")
  }

  private static func step(_ owner: CaptureCarrierOwner) -> Bool {
    defer { ContinuousClock.advance(by: carrierHandoffGracePeriod) }
    return owner.shutdownStep()
  }

  private static func delayedSuccessorRestartsTheQuietInterval() throws {
    let fixture = Fixture()
    let owner = try fixture.owner()
    expect(!owner.shutdownStep(), "initial absence must not complete shutdown")
    ContinuousClock.advance(by: .milliseconds(250))
    expect(!owner.shutdownStep(), "two close samples must not end the supported handoff window")
    ContinuousClock.advance(by: .milliseconds(2500))
    fixture.active = carrier(102)
    expect(!owner.shutdownStep(), "a delayed successor must restart the quiet interval")
    expect(fixture.events.contains("capture:102"), "delayed successor must acquire suppression")
    ContinuousClock.advance(by: .milliseconds(2750))
    expect(!owner.shutdownStep(), "successor cannot inherit the old absence deadline")
    ContinuousClock.advance(by: .milliseconds(250))
    expect(owner.shutdownStep(), "full quiet handoff interval must finish shutdown")
  }

  private static func carrier(_ pid: Int32, version: Int32 = 1) -> AudioProcess {
    AudioProcess(
      bundleID: "com.apple.FaceTime", name: "FaceTime", objectID: UInt32(pid),
      identity: CapturedProcessIdentity(pid: pid, uniqueID: UInt64(pid), version: version), runningOutput: true, trustedIdentity: "com.apple.FaceTime")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      fputs("Capture carrier ownership check failed: \(message)\n", stderr)
      exit(1)
    }
  }

  private final class Tap: CarrierSuppressionTap {
    var stopped = false
    func stop() { self.stopped = true }
  }

  private final class Fixture {
    var active: AudioProcess? = carrier(101)
    var successorAfterSettlement: AudioProcess?
    var discoveryFailures = 0
    var unconfirmed: Set<Int32> = []
    var unavailableTaps: Set<Int32> = []
    var taps: [Int32: Tap] = [:]
    var events: [String] = []

    func owner() throws -> CaptureCarrierOwner {
      ContinuousClock.now = .init(offset: .zero)
      let owner = CaptureCarrierOwner(
        discoverCurrent: {
          if self.discoveryFailures > 0 {
            self.discoveryFailures -= 1
            throw CaptureCarrierOwnerError.terminationUnconfirmed
          }
          return self.active
        },
        startCapture: { process in
          self.events.append("capture:\(process.pid)")
          if self.unavailableTaps.contains(process.pid) {
            throw CaptureCarrierOwnerError.terminationUnconfirmed
          }
          let tap = Tap()
          self.taps[process.pid] = tap
          return tap
        },
        settleCarrier: { process in
          self.events.append("settle:\(process.pid)")
          expect(self.taps[process.pid]?.stopped == false || self.unavailableTaps.contains(process.pid),
                 "settlement follows owned suppression or a failed acquisition attempt")
          if self.unconfirmed.contains(process.pid) { return false }
          if self.active?.hasSameIdentity(as: process) == true {
            self.active = self.successorAfterSettlement
            self.successorAfterSettlement = nil
          }
          return true
        })
      try owner.capture(carrier(101))
      return owner
    }
  }
}
