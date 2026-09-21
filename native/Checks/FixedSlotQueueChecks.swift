import Foundation

@main
private struct FixedSlotQueueChecks {
  static func main() {
    let lock = NSLock()
    let queue = FixedSlotQueue(capacity: 2, lock: lock)
    var preparedSlots: [Int] = []

    precondition(
      queue.tryEnqueue { slot in
        preparedSlots.append(slot)
        return true
      } == .enqueued)
    precondition(
      queue.tryEnqueue { slot in
        preparedSlots.append(slot)
        return true
      } == .enqueued)
    precondition(
      queue.tryEnqueue { slot in
        preparedSlots.append(slot)
        return true
      } == .replacedOldest,
      "saturation must replace stale pending audio instead of failing the bridge")
    precondition(preparedSlots == [0, 1, 0])
    precondition(queue.removeFirst() == 1)
    precondition(
      queue.tryEnqueue { slot in
        precondition(slot == 0)
        return true
      } == .replacedOldest)

    lock.lock()
    precondition(
      queue.tryEnqueue { _ in
        preconditionFailure("contention must drop before preparing a slot")
      } == .droppedContention,
      "ordinary lock contention must drop one capture frame instead of failing the bridge")
    lock.unlock()

    queue.complete(1)

    precondition(
      queue.tryEnqueue { slot in
        precondition(slot == 1)
        return false
      } == .rejected)
    precondition(
      queue.tryEnqueue { slot in
        precondition(slot == 1)
        return true
      } == .enqueued)
    precondition(queue.removeFirst() == 0)
    queue.complete(0)
    precondition(queue.removeFirst() == 1)
    queue.complete(1)
    precondition(queue.removeFirst() == nil)

    let singleSlotQueue = FixedSlotQueue(capacity: 1)
    precondition(singleSlotQueue.tryEnqueue { _ in true } == .enqueued)
    precondition(singleSlotQueue.removeFirst() == 0)
    precondition(
      singleSlotQueue.tryEnqueue { _ in
        preconditionFailure("an active slot must never be overwritten")
      } == .droppedFull)
    singleSlotQueue.complete(0)
  }
}
