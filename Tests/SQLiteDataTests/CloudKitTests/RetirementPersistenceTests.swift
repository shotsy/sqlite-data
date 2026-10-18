#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import GRDB
  @testable import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized)
    final class RetirementPersistenceTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func consumedUploadRetireLateQuotaFailureRestart(delete: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Original") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let id = RemindersList.recordID(for: 1)
        let old = syncEngine.private
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            if delete {
              try RemindersList.find(1).delete().execute(db)
            } else {
              try RemindersList.find(1).update { $0.title = "Updated" }.execute(db)
            }
          }
        }
        if delete {
          old.database.failNextDelete(for: id, with: .quotaExceeded)
        } else {
          old.database.failNextSave(for: id, with: .quotaExceeded)
        }
        let callback = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        #expect(old.state.pendingRecordZoneChanges.isEmpty)
        let snapshot = syncEngine.captureRetirementUploads()
        #expect(snapshot.changes == [delete ? .deleteRecord(id) : .saveRecord(id)])
        syncEngine.stop()
        try await syncEngine.persistRetirementUploads(snapshot)
        await callback.receive()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
        try await syncEngine.start()
        try await syncEngine.sendChanges()
        if delete {
          #expect(throws: (any Error).self) { try old.database.record(for: id) }
        } else {
          #expect(try old.database.record(for: id).encryptedValues["title"] as? String == "Updated")
        }
        // A duplicate late callback or repeated persistence must not replay the old intent.
        await callback.receive()
        try await syncEngine.persistRetirementUploads(snapshot)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
          try #expect(DurableRecordZoneFailure.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func journalRecoversIntoFreshEngine() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Save")
            RemindersList(id: 2, title: "Delete")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Recovered" }.execute(db)
            try RemindersList.find(2).delete().execute(db)
          }
        }
        let snapshot = syncEngine.captureRetirementUploads()
        #expect(snapshot.changes.count == 2)
        syncEngine.stop()
        try await syncEngine.persistRetirementUploads(snapshot)
        let replacement = try await SyncEngine(
          container: container, userDatabase: userDatabase,
          tables: syncEngine.tables, privateTables: syncEngine.privateTables)
        defer { replacement.stop() }
        try await replacement.sendChanges()
        #expect(
          try replacement.private.database.record(for: RemindersList.recordID(for: 1))
            .encryptedValues["title"] as? String == "Recovered")
        #expect(throws: (any Error).self) {
          try replacement.private.database.record(for: RemindersList.recordID(for: 2))
        }
        try await replacement.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedJournalWriteRemainsRetryable() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Recover") }
        }
        let snapshot = syncEngine.captureRetirementUploads()
        syncEngine.stop()
        try await userDatabase.write { db in
          try db.execute(sql: """
            CREATE TEMP TRIGGER retirement_fail_journal
            BEFORE INSERT ON sqlitedata_icloud_pendingRecordZoneChanges
            BEGIN SELECT RAISE(ABORT, 'retirement journal failure'); END
            """)
        }
        await #expect(throws: DatabaseError.self) {
          try await syncEngine.persistRetirementUploads(snapshot)
        }
        #expect(!snapshot.persisted.value)
        try await userDatabase.write { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
          try db.execute(sql: "DROP TRIGGER retirement_fail_journal")
        }
        try await syncEngine.persistRetirementUploads(snapshot)
        try await syncEngine.persistRetirementUploads(snapshot)
        #expect(snapshot.persisted.value)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
        try await syncEngine.start()
        try await syncEngine.sendChanges()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func ordinaryStopStillHandlesLateQuotaFailure() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Legacy") }
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1), with: .quotaExceeded)
        let callback = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        syncEngine.stop()
        await callback.receive()
        try await syncEngine.metadatabase.read { db in
          try #expect(DurableRecordZoneFailure.count().fetchOne(db) == 1)
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func finalCaptureIncludesAdmittedFinisherWithoutReplayingFirstSnapshot() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Queued") }
        }
        let engines = syncEngine.syncEngines.withValue { $0 }
        let first = syncEngine.captureRetirementUploads(engines: engines)
        syncEngine.stop()
        // Model a callback admitted before retirement that queues a retry during quiescence.
        let lateDelete = CKSyncEngine.PendingRecordZoneChange.deleteRecord(
          RemindersList.recordID(for: 2))
        engines.private?.state.add(pendingRecordZoneChanges: [lateDelete])
        let final = syncEngine.captureRetirementUploads(engines: engines)
        #expect(first.changes == [.saveRecord(RemindersList.recordID(for: 1))])
        #expect(final.changes == [lateDelete])
        try await syncEngine.persistRetirementUploads(first)
        try await syncEngine.persistRetirementUploads(final)
        #expect(syncEngine.captureRetirementUploads(engines: engines).changes.isEmpty)
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 2)
        }
        try await syncEngine.start()
        try await syncEngine.sendChanges()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func acknowledgementDoesNotLoseAnotherConsumedSave() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "First") }
        }
        let first = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Second" }.execute(db)
        }
        // Consume a second batch before acknowledging the first one.
        _ = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        await first.receive()
        let snapshot = syncEngine.captureRetirementUploads()
        #expect(snapshot.changes == [.saveRecord(RemindersList.recordID(for: 1))])
        syncEngine.stop()
        try await syncEngine.persistRetirementUploads(snapshot)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [CKError.Code.networkFailure, .unknownItem, .invalidArguments])
      func settledDeleteDoesNotReappearAtRetirement(error: CKError.Code) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Delete") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        syncEngine.private.database.failNextDelete(
          for: RemindersList.recordID(for: 1), with: error)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        if error == .networkFailure {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        let snapshot = syncEngine.captureRetirementUploads()
        #expect(snapshot.changes.isEmpty)
        syncEngine.stop()
        try await syncEngine.persistRetirementUploads(snapshot)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedFailurePersistenceRetainsConsumedDelete() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Delete") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        syncEngine.private.database.failNextDelete(
          for: RemindersList.recordID(for: 1), with: .quotaExceeded)
        let callback = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        try await userDatabase.write { db in
          try db.execute(sql: """
            CREATE TEMP TRIGGER retirement_fail_failure
            BEFORE INSERT ON sqlitedata_icloud_durableRecordZoneFailures
            BEGIN SELECT RAISE(ABORT, 'failure persistence failure'); END
            """)
        }
        await withKnownIssue { await callback.receive() }
        let snapshot = syncEngine.captureRetirementUploads()
        #expect(snapshot.changes == [.deleteRecord(RemindersList.recordID(for: 1))])
        syncEngine.stop()
        try await syncEngine.persistRetirementUploads(snapshot)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func resetInvalidatesSnapshotAndLateResult() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1), with: .quotaExceeded)
        let callback = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        let snapshot = syncEngine.captureRetirementUploads()
        syncEngine.stop()
        try await syncEngine.deleteLocalData()
        await #expect(throws: CancellationError.self) {
          try await syncEngine.persistRetirementUploads(snapshot)
        }
        await callback.receive()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
          try #expect(DurableRecordZoneFailure.count().fetchOne(db) == 0)
        }
        try await syncEngine.sendChanges()
      }
    }
  }
#endif
