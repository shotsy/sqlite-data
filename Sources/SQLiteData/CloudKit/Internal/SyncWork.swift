#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    // Only account-delegate descendants inherit reset ownership, never callback admission.
    @TaskLocal static var accountWork: Work?

    final class Work: Sendable {
      let owner: ObjectIdentifier
      let engines: SyncEngines
      let lifetime: UUID
      let stopRevision: UUID
      let startup: SyncStartup
      let active = LockIsolated(true)
      init(
        owner: ObjectIdentifier, engines: SyncEngines, lifetime: UUID, stopRevision: UUID,
        startup: SyncStartup
      ) {
        self.owner = owner
        self.engines = engines
        self.lifetime = lifetime
        self.stopRevision = stopRevision
        self.startup = startup
      }
    }

    func admit(_ engine: (any SyncEngineProtocol)? = nil, lifetime: UUID? = nil) -> Work? {
      settlement.withAdmission {
        syncEngines.withValue { engines in
          guard !settlement.isDraining,
            let current = try? settlement.currentLifetime(),
            lifetime == nil || lifetime == current,
            engine == nil || engines.private === engine || engines.shared === engine
          else { return nil }
          settlement.begin()
          return Work(
            owner: ObjectIdentifier(self), engines: engines, lifetime: current,
            stopRevision: settlement.stopRevision,
            startup: startup.withValue(\.self))
        }
      }
    }

    func admitCallback(
      _ engine: any SyncEngineProtocol, event: Event? = nil
    ) -> (Work, [SyncAttempt])? {
      settlement.withAdmission {
        guard let work = admit(engine) else { return nil }
        return (work, attempts.admit(engine, event: event))
      }
    }

    // Package handler seams own an epoch just like SDK callbacks. SDK dispatch calls the
    // already-admitted bodies directly, retaining its original owners across every await.
    func withCallback(
      _ engine: any SyncEngineProtocol, event: Event,
      operation: (Work) async -> Void
    ) async {
      guard let (work, owners) = admitCallback(engine, event: event) else { return }
      defer {
        attempts.end(engine)
        finish(work)
      }
      await Self.$attemptOwners.withValue(owners) {
        await operation(work)
        await deliverAttemptFailures(owners)
      }
    }

    func finish(_ work: Work) {
      settlement.withAdmission {
        persistRetiredPendingChanges(engines: work.engines)
        work.active.setValue(false)
        settlement.end()
      }
    }
  }

  final class SyncStartup: Sendable {
    private let state = LockIsolated(
      (finished: false, waiters: [CheckedContinuation<Void, Never>]()))
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

  /// SQL triggers must never acquire settlement: a lease consumer may be waiting for the writer.
  /// Register before spawning, finish after persistence, and wait for the captured frontier only.
  final class SyncMutationTails: Sendable {
    private struct State {
      var next = 0
      var pending: Set<Int> = []
      var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private let state = LockIsolated(State())
    func begin() -> Int {
      state.withValue {
        $0.next += 1
        $0.pending.insert($0.next)
        return $0.next
      }
    }
    func end(_ id: Int) {
      state.withValue { state in
        state.pending.remove(id)
        state.waiters.removeAll { frontier, continuation in
          guard !state.pending.contains(where: { $0 <= frontier }) else { return false }
          continuation.resume()
          return true
        }
      }
    }
    func drain() async {
      await withCheckedContinuation { continuation in
        state.withValue {
          if $0.pending.isEmpty {
            continuation.resume()
          } else {
            $0.waiters.append(($0.next, continuation))
          }
        }
      }
    }
  }
#endif
