#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// Evidence that both scopes finished their current fetch, application and awaited reports.
    ///
    /// This is not a lease or evidence of success: errors and pending retries must be inspected
    /// separately. New work (including automatic fetches), stop and restart invalidate it.
    /// Validate with ``isValid(_:)`` after EVERY suspension before using it to finalize recovery.
    /// Validation is only a point-in-time check, not an atomic transaction with application state.
    public struct SettledToken: Sendable, Equatable {
      fileprivate let epoch: UUID
    }

    /// Waits for current engine work in both scopes, including awaited delegate reports, to drain.
    ///
    /// Does not initiate a fetch or wait for future scheduled retries or pending uploads. A stopped
    /// engine throws `CancellationError`. Cancellation cancels only this wait, not synchronization.
    /// Never await this method from a sync delegate callback or its awaited descendants: the
    /// callback itself must return before settlement is possible. Delegates may query the writer.
    public func waitForSettlement() async throws -> SettledToken {
      try await settlement.wait()
    }

    /// Fetches both scopes and then waits for their current work and awaited reports to drain.
    ///
    /// Throws if fetching fails, the task is cancelled, or the engine stops/restarts during the
    /// operation. The returned token can already be invalidated by new automatic work; validate
    /// it after every await. Like ``waitForSettlement()``, do not await this from a delegate.
    public func fetchChangesAndWaitForSettlement(
      _ options: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions()
    ) async throws -> SettledToken {
      let lifetime = try settlement.currentLifetime()
      try Task.checkCancellation()
      try await fetchChanges(options)
      return try await settlement.wait(lifetime: lifetime)
    }

    /// Whether no new work has begun since this engine issued the token and it is still settled.
    public func isValid(_ token: SettledToken) -> Bool {
      settlement.isValid(token)
    }
  }

  /// Independent of observable activity: retired callbacks must drain even across stop/restart.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  package final class SyncSettlement: Sendable {
    private struct Key: Hashable {
      let engine: ObjectIdentifier
      let activity: SyncEngine.Activity
    }
    private struct State {
      var lifetime: UUID?
      var epoch = UUID()
      var active = 0
      var activities: [Key: Int] = [:]
      var waiters: [UUID: CheckedContinuation<SyncEngine.SettledToken, any Error>] = [:]
      var isSettled: Bool { lifetime != nil && active == 0 && activities.isEmpty }

      mutating func resumeIfSettled() {
        guard isSettled else { return }
        let token = SyncEngine.SettledToken(epoch: epoch)
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations { continuation.resume(returning: token) }
      }
    }
    private let state = LockIsolated(State())

    func start() -> UUID {
      state.withValue {
        let lifetime = UUID()
        $0.lifetime = lifetime
        $0.epoch = UUID()
        return lifetime
      }
    }

    func stop() {
      state.withValue {
        $0.lifetime = nil
        $0.epoch = UUID()
        $0.activities.removeAll()
        let continuations = $0.waiters.values
        $0.waiters.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        // Do not clear active: old callbacks can still write and report after restart.
      }
    }

    func begin() {
      state.withValue {
        $0.epoch = UUID()
        $0.active += 1
      }
    }

    func end() {
      state.withValue {
        $0.active -= 1
        $0.resumeIfSettled()
      }
    }

    func beginEvent(_ event: SyncEngine.Event, engine: any SyncEngineProtocol, isCurrent: Bool) {
      state.withValue {
        $0.epoch = UUID()
        $0.active += 1
        guard isCurrent, let activity = activity(event, starting: true) else { return }
        $0.activities[Key(engine: ObjectIdentifier(engine), activity: activity), default: 0] += 1
      }
    }

    func endEvent(_ event: SyncEngine.Event, engine: any SyncEngineProtocol) {
      state.withValue {
        if let activity = activity(event, starting: false) {
          let key = Key(engine: ObjectIdentifier(engine), activity: activity)
          if let count = $0.activities[key] {
            $0.activities[key] = count > 1 ? count - 1 : nil
          }
        }
        $0.active -= 1
        $0.resumeIfSettled()
      }
    }

    private func activity(_ event: SyncEngine.Event, starting: Bool) -> SyncEngine.Activity? {
      switch (event, starting) {
      case (.willFetchChanges, true), (.didFetchChanges, false): return .fetching
      case (.willFetchRecordZoneChanges(let zone), true),
        (.didFetchRecordZoneChanges(let zone, _), false):
        return .fetchingZone(zone)
      case (.willSendChanges, true), (.didSendChanges, false): return .sending
      default: return nil
      }
    }

    func currentLifetime() throws -> UUID {
      try state.withValue {
        guard let lifetime = $0.lifetime else { throw CancellationError() }
        return lifetime
      }
    }

    func isValid(_ token: SyncEngine.SettledToken) -> Bool {
      state.withValue { $0.isSettled && $0.epoch == token.epoch }
    }

    func wait(lifetime: UUID? = nil) async throws -> SyncEngine.SettledToken {
      let lifetime = try lifetime ?? currentLifetime()
      let id = UUID()
      let token: SyncEngine.SettledToken = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          state.withValue {
            guard !Task.isCancelled, $0.lifetime == lifetime else {
              continuation.resume(throwing: CancellationError())
              return
            }
            $0.waiters[id] = continuation
            $0.resumeIfSettled()
          }
        }
      } onCancel: {
        self.state.withValue {
          $0.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
      }
      try Task.checkCancellation()
      return token
    }
  }
#endif
