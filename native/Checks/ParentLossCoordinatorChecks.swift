import Foundation

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(_ value: Bool) {
    self.value = value
  }

  func set(_ value: Bool) {
    self.lock.lock()
    self.value = value
    self.lock.unlock()
  }

  func get() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    self.lock.lock()
    self.value += 1
    self.lock.unlock()
  }

  func get() -> Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }
}

@main
private struct ParentLossCoordinatorChecks {
  static func main() {
    unexpectedPipeLossFinishesCleanupBeforeStopping()
    concurrentStdinEOFAndStdoutFailureRunCleanupOnce()
    mutedTapStaysUntilCarrierCleanupCompletes()
    safeCloseThenStdoutFailureDoesNotTerminate()
  }

  private static func unexpectedPipeLossFinishesCleanupBeforeStopping() {
    let coordinator = ParentLossCoordinator()
    let stoppingDuringCleanup = Flag(true)
    coordinator.setHandler {
      stoppingDuringCleanup.set(coordinator.isStopping())
    }
    coordinator.notifyParentLost()
    precondition(
      coordinator.isStopping(),
      "unexpected pipe loss must publish stopping after cleanup")
    precondition(
      !stoppingDuringCleanup.get(),
      "unexpected pipe loss must finish carrier cleanup before publishing stopping")
  }

  private static func concurrentStdinEOFAndStdoutFailureRunCleanupOnce() {
    let coordinator = ParentLossCoordinator()
    let cleanupStarted = DispatchSemaphore(value: 0)
    let finishCleanup = DispatchSemaphore(value: 0)
    let invocations = Counter()
    coordinator.setHandler {
      invocations.increment()
      cleanupStarted.signal()
      finishCleanup.wait()
    }

    let group = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      coordinator.notifyParentLost()
    }
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      coordinator.handleUnexpectedParentEOF()
    }

    cleanupStarted.wait()
    coordinator.requestStop()
    precondition(
      !coordinator.isStopping(),
      "concurrent stdin EOF and stdout failure must not publish stopping while cleanup is running")
    precondition(invocations.get() == 1, "parent-loss cleanup must run once")
    finishCleanup.signal()
    group.wait()
    precondition(coordinator.isStopping(), "stopping must publish after the single cleanup")
    precondition(invocations.get() == 1, "a second parent-loss path must not start another teardown")
  }

  private static func mutedTapStaysUntilCarrierCleanupCompletes() {
    let coordinator = ParentLossCoordinator()
    let tapPresent = Flag(true)
    let cleanupStarted = DispatchSemaphore(value: 0)
    let finishCleanup = DispatchSemaphore(value: 0)
    coordinator.setHandler {
      cleanupStarted.signal()
      finishCleanup.wait()
    }

    let group = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      coordinator.notifyParentLost()
    }
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      while !coordinator.isStopping() {
        Thread.sleep(forTimeInterval: 0.001)
      }
      tapPresent.set(false)
    }

    cleanupStarted.wait()
    precondition(
      tapPresent.get(),
      "muted tap must stay until carrier cleanup completes")
    finishCleanup.signal()
    group.wait()
    precondition(!tapPresent.get(), "muted tap may be released after stopping is published")
  }

  private static func safeCloseThenStdoutFailureDoesNotTerminate() {
    let coordinator = ParentLossCoordinator()
    let terminated = Flag(false)
    coordinator.setHandler {
      terminated.set(true)
    }
    coordinator.markCloseSafe()
    coordinator.handleUnexpectedParentEOF()
    precondition(
      !coordinator.isStopping(),
      "safe-close stdin EOF must leave capture running")
    coordinator.notifyParentLost()
    precondition(
      !terminated.get(),
      "safe-close must not terminate the carrier when stdout later fails")
    precondition(
      coordinator.isStopping(),
      "stdout failure after safe-close must still stop capture")
  }
}
