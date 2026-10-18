#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class RetirementUploads: Sendable {
    private struct Entry {
      weak var engine: (any SyncEngineProtocol)?
      let generation: UUID
      var inFlight: [CKSyncEngine.PendingRecordZoneChange: Int] = [:]
      var retired = false
      var captured: Set<CKSyncEngine.PendingRecordZoneChange> = []
    }
    private struct State {
      var generation = UUID()
      var entries: [ObjectIdentifier: Entry] = [:]
    }
    private let state = LockIsolated(State())

    final class Snapshot: Sendable {
      fileprivate let owner: RetirementUploads
      fileprivate let generation: UUID
      let changes: [CKSyncEngine.PendingRecordZoneChange]
      let persisted = LockIsolated(false)
      fileprivate init(
        owner: RetirementUploads, generation: UUID,
        changes: [CKSyncEngine.PendingRecordZoneChange]
      ) {
        self.owner = owner
        self.generation = generation
        self.changes = changes
      }
    }

    func register(_ engines: SyncEngines) {
      state.withValue { state in
        state.entries = state.entries.filter { $0.value.engine != nil }
        for engine in [engines.private, engines.shared].compactMap({ $0 }) {
          state.entries[ObjectIdentifier(engine)] = Entry(engine: engine, generation: state.generation)
        }
      }
    }

    func isRetired(_ engine: any SyncEngineProtocol) -> Bool {
      state.withValue { $0.entries[ObjectIdentifier(engine)]?.retired == true }
    }

    // Register before the SDK can consume its queue, not after the async batch provider returns.
    func begin(
      _ changes: [CKSyncEngine.PendingRecordZoneChange], engine: any SyncEngineProtocol
    ) -> Bool {
      state.withValue { state in
        let key = ObjectIdentifier(engine)
        guard state.entries[key]?.retired != true else { return false }
        for change in changes {
          state.entries[key]?.inFlight[change, default: 0] += 1
        }
        return true
      }
    }

    func acknowledge(_ changes: [CKSyncEngine.PendingRecordZoneChange], engine: any SyncEngineProtocol) {
      state.withValue { state in
        let key = ObjectIdentifier(engine)
        for change in changes {
          guard let count = state.entries[key]?.inFlight[change] else { continue }
          state.entries[key]?.inFlight[change] = count > 1 ? count - 1 : nil
        }
      }
    }

    // Slice c must mark under lifecycle admission, quiesce admitted handlers/providers, THEN
    // capture. Freezing a snapshot before quiescence could replay a subsequently successful delete.
    func markRetiring(_ engines: SyncEngines) {
      state.withValue { state in
        for engine in [engines.private, engines.shared].compactMap({ $0 }) {
          let key = ObjectIdentifier(engine)
          guard state.entries[key]?.generation == state.generation else { continue }
          state.entries[key]?.retired = true
        }
      }
    }

    // Explicit retirement only. Ordinary stop() neither calls this nor rejects callbacks.
    // Capture only after quiescence (or in tests with no admitted work). Each capture is a delta:
    // retain ALL snapshots until persistence succeeds, and persist before allowing restart.
    // Failure must not be reported as a successful drain. Never recapture to retry a failed write.
    func capture(_ engines: SyncEngines) -> Snapshot {
      state.withValue { state in
        var changes: Set<CKSyncEngine.PendingRecordZoneChange> = []
        for engine in [engines.private, engines.shared].compactMap({ $0 }) {
          let key = ObjectIdentifier(engine)
          guard var entry = state.entries[key], entry.generation == state.generation else { continue }
          entry.retired = true
          let pending = Set(entry.inFlight.keys).union(engine.state.pendingRecordZoneChanges)
          changes.formUnion(pending.subtracting(entry.captured))
          entry.captured.formUnion(pending)
          state.entries[key] = entry
        }
        return Snapshot(owner: self, generation: state.generation, changes: Array(changes))
      }
    }

    func validate(_ snapshot: Snapshot) throws {
      guard snapshot.owner === self,
        state.withValue({ $0.generation == snapshot.generation })
      else { throw CancellationError() }
    }

    // Called on the user writer, serialized with journal persistence. Never replay an old
    // account's snapshot into the replacement metadata database, even after a failed write.
    func invalidate() {
      state.withValue { state in
        state.generation = UUID()
        for key in state.entries.keys {
          state.entries[key]?.inFlight.removeAll()
          state.entries[key]?.captured.removeAll()
        }
      }
    }
  }
#endif
