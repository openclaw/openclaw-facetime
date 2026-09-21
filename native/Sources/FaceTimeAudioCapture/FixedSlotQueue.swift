import Foundation

enum FixedSlotQueueEnqueueResult: Equatable {
  case enqueued
  case replacedOldest
  case droppedContention
  case droppedFull
  case rejected
}

final class FixedSlotQueue: @unchecked Sendable {
  private let lock: NSLock
  private let available: FixedSlotRing
  private let pending: FixedSlotRing
  private var activeSlot: Int?

  init(capacity: Int, lock: NSLock = NSLock()) {
    precondition(capacity > 0)
    self.lock = lock
    self.available = FixedSlotRing(capacity: capacity)
    self.pending = FixedSlotRing(capacity: capacity)
    for slot in 0..<capacity {
      precondition(self.available.append(slot))
    }
  }

  func tryEnqueue(prepare: (Int) -> Bool) -> FixedSlotQueueEnqueueResult {
    guard self.lock.try() else { return .droppedContention }
    defer { self.lock.unlock() }
    let freeSlot = self.available.removeFirst()
    let slot = freeSlot ?? self.pending.removeFirst()
    guard let slot else { return .droppedFull }
    guard prepare(slot) else {
      precondition(self.available.append(slot))
      return .rejected
    }
    precondition(self.pending.append(slot))
    return freeSlot == nil ? .replacedOldest : .enqueued
  }

  func removeFirst() -> Int? {
    self.lock.lock()
    defer { self.lock.unlock() }
    precondition(self.activeSlot == nil)
    guard let slot = self.pending.removeFirst() else { return nil }
    self.activeSlot = slot
    return slot
  }

  func complete(_ slot: Int) {
    self.lock.lock()
    defer { self.lock.unlock() }
    precondition(self.activeSlot == slot)
    self.activeSlot = nil
    precondition(self.available.append(slot))
  }
}
