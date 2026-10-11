import Foundation

extension Process {
  /// `run()`, plus a semaphore signaled when the process exits: wait on it
  /// instead of calling `waitUntilExit()`. That one waits for the exit on
  /// the calling thread's run loop, and on a background thread it can miss
  /// it and block forever. In the Mail widget that left a HEY read
  /// "running" for good, so no later refresh ran and deleted mail stayed
  /// in the list.
  public func runSignalingExit() throws -> DispatchSemaphore {
    let exited = DispatchSemaphore(value: 0)
    terminationHandler = { _ in exited.signal() }
    try run()
    return exited
  }
}
