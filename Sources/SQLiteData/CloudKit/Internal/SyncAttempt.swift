#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras
  import Foundation
  import IssueReporting

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// Immutable observations for one explicit fetch or send, across both database scopes.
    /// Success means admitted processing settled without observed failures, not that all cloud
    /// records were transferred, retries completed, or local values exactly match the server.
    public struct AttemptReceipt: Sendable {
      public enum Result: Sendable { case succeeded, failed, unconfirmed }
      /// A fresh library-generated attempt epoch, independent of account and transfer tokens.
      public let attemptID: UUID
      public let result: Result
      public let failures: [Failure]
      public let settlementToken: SettledToken

      public struct Failure: Sendable {
        public let attemptID: UUID
        public let error: any Error
        public let context: SyncEngineErrorContext
      }
    }

    /// Fetches and returns failures (including ordinary thrown errors) after both scopes settle.
    /// Overlap with other explicit work or already-admitted callbacks is unconfirmed. CloudKit
    /// supplies no request ID: callbacks admitted during an attempt are conservatively attributed
    /// to it; ambiguous callbacks belong to all overlapping attempts. Captured ownership never
    /// changes across awaits. Failure takes precedence over unconfirmed attribution. Automatic
    /// callbacks during this aggregate attempt are included. Standalone automatic cycles publish
    /// failure receipts through the delegate, but never publish successful settlement evidence.
    ///
    /// Cancellation, stop/restart and account changes throw CancellationError, not success.
    /// This does not stop or drain retired engines, or wait for future scheduled retries. Never
    /// call from an awaited sync delegate. Validate/consume the token with withSettlementLease.
    public func fetchChangesWithReceipt(
      _ options: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions()
    ) async throws -> AttemptReceipt {
      try await runAttempt(receipt: true) { try await self.performFetchChanges(options) }!
    }

    /// Sends and returns a settled receipt with the same attribution and cancellation rules as
    /// fetchChangesWithReceipt. Pending uploads and future retries are not proof of failure or
    /// success; the receipt describes only processing observed during this attempt.
    public func sendChangesWithReceipt(
      _ options: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions()
    ) async throws -> AttemptReceipt {
      try await runAttempt(receipt: true) { try await self.performSendChanges(options) }!
    }

    @TaskLocal static var attemptOwners: [SyncAttempt] = []

    func runAttempt(
      receipt: Bool, operation: @Sendable () async throws -> Void
    ) async throws -> AttemptReceipt? {
      let (lifetime, attempt) = try settlement.withAdmission {
        let lifetime = receipt ? try settlement.currentLifetime() : nil
        let busy = settlement.hasWork
        let attempt = attempts.begin(
          engines: syncEngines.withValue { [$0.private, $0.shared].compactMap { $0 } })
        if busy { attempt.state.withValue { $0.uncertain = true } }
        settlement.begin()
        return (lifetime, attempt)
      }
      defer { attempts.remove(attempt) }
      var operationError: (any Error)?
      await Self.$attemptOwners.withValue([attempt]) {
        do { try await operation() } catch { operationError = error }
      }
      await deliverAttemptFailures([attempt])
      settlement.end()
      if !receipt {
        if let operationError { throw operationError }
        return nil
      }
      if operationError is CancellationError { throw CancellationError() }
      while true {
        let token = try await settlement.wait(lifetime: lifetime)
        try Task.checkCancellation()
        // Admission and final snapshot share the settlement lock. No callback can be admitted
        // between this validation and closing the immutable receipt.
        if let result = try settlement.withAdmission({ () throws -> AttemptReceipt? in
          guard try settlement.currentLifetime() == lifetime, !attempt.state.invalid else {
            throw CancellationError()
          }
          guard settlement.isValid(token) else { return nil }
          let current = syncEngines.withValue {
            Set([$0.private, $0.shared].compactMap { $0 }.map(ObjectIdentifier.init))
          }
          guard current == attempt.engines else { throw CancellationError() }
          return attempts.finish(attempt, token: token)
        }) {
          return result
        }
      }
    }

    func recordAttemptFailure(
      _ error: any Error, context: SyncEngineErrorContext,
      owners: [SyncAttempt] = SyncEngine.attemptOwners
    ) {
      for attempt in owners {
        attempt.state.withValue {
          guard !$0.closed else { return }
          $0.failures.append(.init(attemptID: attempt.id, error: error, context: context))
        }
      }
    }

    func deliverAttemptFailures(_ owners: [SyncAttempt]) async {
      for attempt in owners {
        let failures = attempt.state.withValue { state in
          let failures = Array(state.failures.dropFirst(state.delivered))
          state.delivered = state.failures.count
          return failures
        }
        for failure in failures {
          await delegate?.syncEngine(self, didReportFailure: failure)
        }
      }
    }

    func reportError(_ error: any Error, context: SyncEngineErrorContext) async {
      recordAttemptFailure(error, context: context)
      await delegate?.syncEngine(self, didReportError: error, context: context)
    }

    func withAttemptErrorReporting<T>(
      _ context: SyncEngineErrorContext = SyncEngineErrorContext(operation: "syncPersistence"),
      catching body: () async throws -> T
    ) async -> T? {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        do { return try await body() } catch {
          recordAttemptFailure(error, context: context)
          throw error
        }
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncAttempt: Sendable {
    let id = UUID()
    let engines: Set<ObjectIdentifier>
    struct State {
      var failures: [SyncEngine.AttemptReceipt.Failure] = []
      var uncertain = false
      var invalid = false
      var closed = false
      var delivered = 0
    }
    let state = LockIsolated(State())
    init(engines: Set<ObjectIdentifier>) { self.engines = engines }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncAttempts: Sendable {
    private struct State {
      var attempts: [UUID: SyncAttempt] = [:]
      var callbacks: [ObjectIdentifier: Int] = [:]
      var automatic: [AutomaticKey: SyncAttempt] = [:]
    }
    private struct AutomaticKey: Hashable {
      let engine: ObjectIdentifier
      let upload: Bool
    }
    private let state = LockIsolated(State())

    func begin(engines: [any SyncEngineProtocol]) -> SyncAttempt {
      state.withValue { state in
        let attempt = SyncAttempt(engines: Set(engines.map(ObjectIdentifier.init)))
        for other in state.attempts.values {
          other.state.withValue { $0.uncertain = true }
          attempt.state.withValue { $0.uncertain = true }
        }
        if state.callbacks.values.contains(where: { $0 > 0 }) || engines.count != 2 {
          attempt.state.withValue { $0.uncertain = true }
        }
        state.attempts[attempt.id] = attempt
        return attempt
      }
    }

    func admit(_ engine: any SyncEngineProtocol, event: SyncEngine.Event? = nil) -> [SyncAttempt] {
      state.withValue { state in
        let id = ObjectIdentifier(engine)
        state.callbacks[id, default: 0] += 1
        let upload: Bool
        switch event {
        case .sentDatabaseChanges?, .sentRecordZoneChanges?, .willSendChanges?, .didSendChanges?,
          nil:
          upload = true
        default: upload = false
        }
        let key = AutomaticKey(engine: id, upload: upload)
        let owners = state.attempts.values.filter { $0.engines.contains(id) }
        // Retired callbacks still share the writer until stop/drain closes their admission.
        for attempt in state.attempts.values where !attempt.engines.contains(id) {
          attempt.state.withValue { $0.uncertain = true }
        }
        if case .stateUpdate? = event {
          let automatic = state.automatic.filter { $0.key.engine == id }.map(\.value)
          if !owners.isEmpty || !automatic.isEmpty { return owners + automatic }
        }
        // Automatic epochs are conservative lifecycle windows, not CloudKit request IDs.
        // Missing will-events get a fresh fallback epoch; overlapping boundaries cannot prove
        // unique attribution. Captured callbacks retain the old epoch after a did-event.
        switch event {
        case .willFetchChanges?, .willSendChanges?:
          if owners.isEmpty { state.automatic[key] = SyncAttempt(engines: [id]) }
        default: break
        }
        if state.automatic[key] == nil && owners.isEmpty {
          state.automatic[key] = SyncAttempt(engines: [id])
        }
        let automatic = state.automatic[key]
        switch event {
        case .didFetchChanges?, .didSendChanges?: state.automatic[key] = nil
        default: break
        }
        if case .accountChange? = event { state.automatic.removeAll() }
        return owners + (automatic.map { [$0] } ?? [])
      }
    }

    func end(_ engine: any SyncEngineProtocol) {
      state.withValue {
        let id = ObjectIdentifier(engine)
        $0.callbacks[id, default: 0] -= 1
        if $0.callbacks[id] == 0 { $0.callbacks[id] = nil }
      }
    }

    func invalidate() {
      state.withValue {
        $0.attempts.values.forEach { $0.state.withValue { $0.invalid = true } }
        $0.automatic.removeAll()
      }
    }

    func remove(_ attempt: SyncAttempt) {
      state.withValue { $0.attempts[attempt.id] = nil }
    }

    func finish(_ attempt: SyncAttempt, token: SyncEngine.SettledToken) -> SyncEngine.AttemptReceipt
    {
      let receipt = attempt.state.withValue {
        $0.closed = true
        return SyncEngine.AttemptReceipt(
          attemptID: attempt.id,
          result: !$0.failures.isEmpty ? .failed : $0.uncertain ? .unconfirmed : .succeeded,
          failures: $0.failures, settlementToken: token
        )
      }
      remove(attempt)
      return receipt
    }
  }
#endif
