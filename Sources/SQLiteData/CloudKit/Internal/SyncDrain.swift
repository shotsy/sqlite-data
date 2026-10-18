#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncDrain: Sendable {
    struct State {
      var epoch = UUID()
      var closed = false
      var task: Task<Void, any Error>?
      var engines: [any SyncEngineProtocol] = []
      var snapshot: RetirementUploads.Snapshot?
      var startup: SyncCompletion?
    }
    // Always accessed under settlement admission. SQL tails have an independent lock below.
    let state = LockIsolated(State())
  }

  final class SyncCompletion: Sendable {
    private let state = LockIsolated((finished: false, waiters: [CheckedContinuation<Void, Never>]()))
    func wait() async {
      await withCheckedContinuation { continuation in
        state.withValue {
          if $0.finished { continuation.resume() } else { $0.waiters.append(continuation) }
        }
      }
    }
    func finish() {
      state.withValue {
        $0.finished = true
        for waiter in $0.waiters { waiter.resume() }
        $0.waiters.removeAll()
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    struct Work: Sendable {
      let engines: SyncEngines
      let startup: SyncCompletion?
      let epoch: UUID
    }
    struct AccountOwner: Sendable {
      let owner: ObjectIdentifier
      let epoch: UUID
      let isPrivate: Bool
    }
    @TaskLocal static var accountOwner: AccountOwner?

    // Call only under settlement admission; ordinary stop does not close this gate.
    func admits(_ engine: (any SyncEngineProtocol)? = nil, epoch: UUID? = nil) -> Bool {
      !drainState.state.closed && (epoch == nil || epoch == drainState.state.epoch)
        && (engine == nil || !retirementUploads.isRetired(engine!))
    }
    func captureWork() throws -> Work {
      guard admits() else { throw CancellationError() }
      return Work(engines: syncEngines.value, startup: drainState.state.startup,
        epoch: drainState.state.epoch)
    }
    func operationEngines(_ work: Work) async throws -> SyncEngines {
      await work.startup?.wait()
      return try settlement.withAdmission {
        guard admits(epoch: work.epoch) else { throw CancellationError() }
        return syncEngines.value  // Preserve ordinary stop/reset selection after startup.
      }
    }
    func beginDeferred(epoch: UUID, engine: (any SyncEngineProtocol)? = nil) -> Bool {
      settlement.withAdmission {
        guard admits(engine, epoch: epoch) else { return false }
        settlement.begin()
        return true
      }
    }

    /// Stops synchronization and drains admitted work, awaited delegates and persistence tails.
    /// Unlike `stop()`, permanently rejects subsequent callbacks from all owned retired engines.
    /// Concurrent callers share a barrier; cancelling a caller does not shorten it. Starts are
    /// rejected during drain and after persistence failure until a successful drain retry.
    /// Does not freeze app-owned writes, sharing or surveys, or guarantee remote CloudKit success.
    /// Never await from a sync delegate/its awaited descendants, or while holding the writer.
    public func stopAndDrain() async throws {
      let task = settlement.withAdmission {
        drainState.state.withValue { state -> Task<Void, any Error> in
          if let task = state.task { return task }
          if !state.closed {
            state.closed = true
            state.epoch = UUID()
            retirementUploads.register(syncEngines.value)
            state.engines = retirementUploads.retireAll()
          }
          let task = Task {
            self.stop()
            self.settlement.withAdmission {
              self.settlement.stop()
              self.attempts.invalidate()
            }
            do {
              await self.settlement.drain()
              self.clearRetiredTransfers()
              await self.mutationTails.drain()
              try await self.flushMutationTails()
              let snapshot = self.settlement.withAdmission {
                self.drainState.state.withValue { state in
                  if let snapshot = state.snapshot { return snapshot }
                  let snapshot = self.retirementUploads.capture(state.engines)
                  state.snapshot = snapshot
                  return snapshot
                }
              }
              try await self.persistRetirementUploads(snapshot)
              self.settlement.withAdmission {
                self.drainState.state.withValue { state in
                  state.closed = false
                  state.task = nil
                  state.engines.removeAll()
                  state.snapshot = nil
                }
              }
            } catch {
              self.settlement.withAdmission { self.drainState.state.withValue { $0.task = nil } }
              throw error
            }
          }
          state.task = task
          return task
        }
      }
      try await task.value
    }
  }

  /// Register before spawning, finish after persistence. Never acquire settlement from SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncMutationTails: Sendable {
    struct Entry: Sendable {
      let id: Int
      let generation: UUID
      let changes: [CKSyncEngine.PendingRecordZoneChange]
    }
    struct State {
      var next = 0
      var entries: [Entry] = []
      var pending: Set<Int> = []
      var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    let state = LockIsolated(State())
    func begin(_ changes: [CKSyncEngine.PendingRecordZoneChange], generation: UUID) -> Int {
      state.withValue {
        $0.next += 1
        $0.entries.append(Entry(id: $0.next, generation: generation, changes: changes))
        $0.pending.insert($0.next)
        return $0.next
      }
    }
    func end(_ id: Int) {
      state.withValue { state in
        state.pending.remove(id)
        let pending = state.pending
        state.waiters.removeAll { frontier, continuation in
          guard !pending.contains(where: { $0 <= frontier }) else { return false }
          continuation.resume()
          return true
        }
      }
    }
    func drain() async {
      await withCheckedContinuation { continuation in
        state.withValue {
          if $0.pending.isEmpty { continuation.resume() }
          else { $0.waiters.append(($0.next, continuation)) }
        }
      }
    }
  }
#endif
