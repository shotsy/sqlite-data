#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import Foundation
  import GRDB
  @testable import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized)
    final class AdditiveDrainTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: ["fetch", "send", "sync", "fetchReceipt", "sendReceipt"])
      func pendingStartupAndExplicitOperation(operation: String) async throws {
        syncEngine.stop()
        let gate = DrainSQLGate()
        defer { gate.open() }
        try await userDatabase.write { db in
          db.add(function: DatabaseFunction("drain_start_gate", argumentCount: 0) { _ in
            gate.blockOnce()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_start AFTER UPDATE ON sqlitedata_icloud_recordTypes
            BEGIN SELECT drain_start_gate(); END
            """)
        }
        let start = Task { try await syncEngine.start() }
        await gate.entered.wait()
        var explicit: Task<Void, any Error>!
        await withMainSerialExecutor {
          explicit = Task {
            switch operation {
            case "send": try await syncEngine.sendChanges()
            case "sync": try await syncEngine.syncChanges()
            case "fetchReceipt": _ = try await syncEngine.fetchChangesWithReceipt()
            case "sendReceipt": _ = try await syncEngine.sendChangesWithReceipt()
            default: try await syncEngine.fetchChanges()
            }
          }
          await Task.yield()
        }
        let (drain, finished) = await beginDrain()
        #expect(!finished.value)
        #expect(!syncEngine.isRunning)
        await #expect(throws: CancellationError.self) { try await syncEngine.start() }
        gate.open()
        try await start.value
        await #expect(throws: CancellationError.self) { try await explicit.value }
        try await drain.value
        #expect(finished.value)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func explicitSDKCallIsCounted(send: Bool) async throws {
        let engine = DrainProtocolEngine(base: syncEngine.private)
        syncEngine.syncEngines.setValue(SyncEngines(private: engine, shared: syncEngine.shared))
        let operation = Task {
          if send { try await syncEngine.sendChanges() }
          else { try await syncEngine.fetchChanges() }
        }
        await engine.entered.wait()
        let (drain, finished) = await beginDrain()
        #expect(!finished.value)
        engine.release.finish()
        try await operation.value
        try await drain.value
        #expect(finished.value)
        #expect(engine.calls.value == 1)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func providerIsCountedAndCannotReenterAfterDrain() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Provider") }
        }
        let engine = DrainProtocolEngine(base: syncEngine.private)
        syncEngine.syncEngines.setValue(SyncEngines(private: engine, shared: syncEngine.shared))
        syncEngine.retirementUploads.register(syncEngine.syncEngines.value)
        let gate = DrainSQLGate()
        defer { gate.open() }
        try await userDatabase.write { db in
          db.add(function: DatabaseFunction("drain_provider_gate", argumentCount: 0) { _ in
            gate.blockOnce()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_provider AFTER UPDATE ON sqlitedata_icloud_metadata
            BEGIN SELECT drain_provider_gate(); END
            """)
        }
        let provided = Task { await syncEngine.nextRecordZoneChangeBatch(syncEngine: engine) }
        await gate.entered.wait()
        let (drain, finished) = await beginDrain()
        #expect(!finished.value)
        gate.open()
        _ = await provided.value
        #expect(engine.provided.value)
        try await drain.value
        #expect(await syncEngine.nextRecordZoneChangeBatch(syncEngine: engine) == nil)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stoppedTriggerTailMustCommitBeforeDrainReturns() async throws {
        syncEngine.stop()
        let gate = DrainSQLGate()
        defer { gate.open() }
        try await userDatabase.write { db in
          db.add(function: DatabaseFunction("drain_tail_gate", argumentCount: 0) { _ in
            gate.blockOnce()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_tail BEFORE INSERT ON sqlitedata_icloud_pendingRecordZoneChanges
            BEGIN SELECT drain_tail_gate(); END
            """)
        }
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Tail") }
        }
        await gate.entered.wait()
        let (drain, finished) = await beginDrain()
        #expect(!finished.value)
        gate.open()
        try await drain.value
        #expect(syncEngine.mutationTails.state.value.entries.isEmpty)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedTriggerTailIsRetainedUntilDrainRetry() async throws {
        syncEngine.stop()
        try await userDatabase.write { db in
          try db.execute(sql: """
            CREATE TEMP TRIGGER fail_tail BEFORE INSERT ON sqlitedata_icloud_pendingRecordZoneChanges
            BEGIN SELECT RAISE(ABORT, 'tail persistence failure'); END
            """)
        }
        await withKnownIssue {
          try await userDatabase.userWrite { db in
            try db.seed { RemindersList(id: 1, title: "Tail retry") }
          }
          await syncEngine.mutationTails.drain()
        }
        #expect(!syncEngine.mutationTails.state.value.entries.isEmpty)
        await #expect(throws: DatabaseError.self) { try await syncEngine.stopAndDrain() }
        await #expect(throws: CancellationError.self) { try await syncEngine.start() }
        try await userDatabase.write { db in try db.execute(sql: "DROP TRIGGER fail_tail") }
        try await syncEngine.stopAndDrain()
        #expect(syncEngine.mutationTails.state.value.entries.isEmpty)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func legacyRetryTimerCannotWakeIntoRestartAfterDrain() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Retry") }
        }
        let old = syncEngine.private
        old.database.failNextSave(for: RemindersList.recordID(for: 1), with: .quotaExceeded)
        try await syncEngine.sendChanges()
        try await syncEngine.stopAndDrain()
        let failure = try await userDatabase.write { db in
          let failure = try #require(try DurableRecordZoneFailure.all.fetchOne(db))
          try DurableRecordZoneFailure.delete().execute(db)
          return failure
        }
        try await syncEngine.start()
        // Startup saw no failures and scheduled no replacement timer. Reintroduce the row
        // solely to detect whether the old timer can target the new engine after waking.
        try await userDatabase.write { db in
          try DurableRecordZoneFailure.insert { failure }.execute(db)
        }
        await testClock.advance(by: .seconds(60))
        syncEngine.private.state.assertPendingRecordZoneChanges([])
        try await syncEngine.stopAndDrain()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func failedRetirementPersistenceRetainsSnapshot(consumed: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Durable") }
        }
        let old = syncEngine.private
        if consumed {
          old.database.failNextSave(for: RemindersList.recordID(for: 1), with: .quotaExceeded)
          _ = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
          #expect(old.state.pendingRecordZoneChanges.isEmpty)
        }
        try await userDatabase.write { db in
          try db.execute(sql: """
            CREATE TEMP TRIGGER fail_drain BEFORE INSERT ON sqlitedata_icloud_pendingRecordZoneChanges
            BEGIN SELECT RAISE(ABORT, 'drain persistence failure'); END
            """)
        }
        await #expect(throws: DatabaseError.self) { try await syncEngine.stopAndDrain() }
        let snapshot = try #require(syncEngine.drainState.state.value.snapshot)
        #expect(!snapshot.persisted.value)
        #expect(snapshot.changes == [.saveRecord(RemindersList.recordID(for: 1))])
        await #expect(throws: CancellationError.self) { try await syncEngine.start() }
        await #expect(throws: CancellationError.self) { try await syncEngine.sendChanges() }
        try await userDatabase.write { db in try db.execute(sql: "DROP TRIGGER fail_drain") }
        try await syncEngine.stopAndDrain()
        #expect(snapshot.persisted.value)
        try await syncEngine.start()
        try await syncEngine.sendChanges()
        #expect(try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
          .encryptedValues["title"] as? String == "Durable")
        try await syncEngine.stopAndDrain()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func resetAlreadyAdmittedCannotRestartAfterDrain() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        let gate = DrainSQLGate()
        defer { gate.open() }
        try await userDatabase.write { db in
          db.add(function: DatabaseFunction("drain_reset_gate", argumentCount: 0) { _ in
            gate.blockOnce()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_reset AFTER DELETE ON remindersLists
            BEGIN SELECT drain_reset_gate(); END
            """)
        }
        let reset = Task { try await syncEngine.deleteLocalData() }
        await gate.entered.wait()
        let (drain, finished) = await beginDrain()
        #expect(!finished.value)
        gate.open()
        try await reset.value
        try await drain.value
        #expect(!syncEngine.isRunning)
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func beginDrain() async -> (Task<Void, any Error>, LockIsolated<Bool>) {
        let finished = LockIsolated(false)
        var task: Task<Void, any Error>!
        await withMainSerialExecutor {
          task = Task {
            try await syncEngine.stopAndDrain()
            finished.setValue(true)
          }
          await Task.yield()
        }
        return (task, finished)
      }
    }
  }

  private final class DrainSQLGate: Sendable {
    let entered = SyncCompletion()
    private let release = DispatchSemaphore(value: 0)
    private let blocked = LockIsolated(false)
    func blockOnce() {
      guard blocked.withValue({ value in
        guard !value else { return false }
        value = true
        return true
      }) else { return }
      entered.finish()
      release.wait()
    }
    func open() { release.signal() }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class DrainProtocolEngine: SyncEngineProtocol {
    let base: MockSyncEngine
    var database: MockCloudDatabase { base.database }
    var state: MockSyncEngineState { base.state }
    let entered = SyncCompletion()
    let release = SyncCompletion()
    let calls = LockIsolated(0)
    let provided = LockIsolated(false)
    init(base: MockSyncEngine) { self.base = base }
    func cancelOperations() async {}
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
      calls.withValue { $0 += 1 }
      entered.finish()
      await release.wait()
    }
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
      try await fetchChanges(CKSyncEngine.FetchChangesOptions())
    }
    func recordZoneChangeBatch(
      pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
      recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      for change in pendingChanges {
        if case .saveRecord(let id) = change {
          let record = await recordProvider(id)
          provided.setValue(record != nil)
        }
      }
      return nil
    }
  }
#endif
