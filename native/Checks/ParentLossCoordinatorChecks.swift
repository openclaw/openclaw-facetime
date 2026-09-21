import Foundation

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
    concurrentStdinEOFAndStdoutFailureRunCleanupOnce()
    safeCloseThenStdoutFailureDoesNotTerminate()
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
      coordinator.handleOutputClosed()
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

  private static func safeCloseThenStdoutFailureDoesNotTerminate() {
    let coordinator = ParentLossCoordinator()
    let terminated = Counter()
    coordinator.setHandler {
      terminated.increment()
    }
    coordinator.markCloseSafe()
    coordinator.handleUnexpectedParentEOF()
    precondition(
      !coordinator.isStopping(),
      "safe-close stdin EOF must leave capture running")
    coordinator.handleOutputClosed()
    precondition(
      terminated.get() == 0,
      "safe-close must not terminate the carrier when stdout later fails")
    precondition(
      coordinator.isStopping(),
      "stdout failure after safe-close must still stop capture")
  }

}
