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
    final class RetirementPersistenceTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func editAndDeleteImmediatelyBeforeRetirement(drain: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Edit")
            RemindersList(id: 2, title: "Delete")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let old = syncEngine.private
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Edited" }.execute(db)
            try RemindersList.find(2).delete().execute(db)
          }
        }
        // MockSyncEngine never emits stateUpdate: retirement must not depend on it.
        #expect(
          old.state.pendingRecordZoneChanges.contains(.saveRecord(RemindersList.recordID(for: 1))))
        #expect(
          old.state.pendingRecordZoneChanges.contains(.deleteRecord(RemindersList.recordID(for: 2)))
        )
        if drain { try await syncEngine.stopAndDrain() } else { syncEngine.stop() }
        try await syncEngine.start()
        try await syncEngine.sendChanges()
        #expect(
          try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
            .encryptedValues["title"] as? String == "Edited")
        #expect(throws: (any Error).self) {
          try syncEngine.private.database.record(for: RemindersList.recordID(for: 2))
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopDuringStartupJournalReadPreservesHandoff() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Before") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.stopAndDrain()
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "After" }.execute(db)
          }
        }
        try await syncEngine.stopAndDrain()
        let gate = RetirementSQLGate()
        defer { gate.open() }
        // Cover both the old metadata-reader path and the transactional writer path.
        for writer in [userDatabase.database, syncEngine.metadatabase] {
          try await writer.write { db in
            db.trace { event in
              let sql = event.description.lowercased()
              if sql.contains("select"), sql.contains("sqlitedata_icloud_pendingrecordzonechanges")
              {
                gate.block()
              }
            }
          }
        }
        let starting = Task { try await syncEngine.start() }
        await gate.entered.wait()
        syncEngine.stop()
        gate.open()
        try await starting.value
        try await syncEngine.stopAndDrain()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
        try await syncEngine.start()
        try await syncEngine.sendChanges()
        #expect(
          try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
            .encryptedValues["title"] as? String == "After")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedJournalWriteRetriesOnRestart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Recover") }
        }
        try await userDatabase.write { db in
          try db.execute(
            sql: """
              CREATE TEMP TRIGGER retirement_fail_journal
              BEFORE INSERT ON sqlitedata_icloud_pendingRecordZoneChanges
              BEGIN SELECT RAISE(ABORT, 'retirement journal failure'); END
              """)
        }
        await withKnownIssue {
          await #expect(throws: DatabaseError.self) {
            try await syncEngine.stopAndDrain()
          }
        }
        #expect(!syncEngine.isRunning)
        try await userDatabase.write { db in
          try db.execute(sql: "DROP TRIGGER retirement_fail_journal")
        }
        try await syncEngine.stopAndDrain()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
        try await syncEngine.start()
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.contains(
            .saveRecord(RemindersList.recordID(for: 1))))
        try await syncEngine.sendChanges()
        #expect(
          try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
            .encryptedValues["title"] as? String == "Recover")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func accountResetDiscardsRetiredUploadsAndLateFinishers() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        let old = syncEngine.private
        let work = try #require(syncEngine.admit(old))
        try await syncEngine.deleteLocalData()
        old.state.add(pendingRecordZoneChanges: [.deleteRecord(RemindersList.recordID(for: 1))])
        syncEngine.finish(work)
        try await syncEngine.stopAndDrain()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
        }
        try await syncEngine.start()
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        try await syncEngine.sendChanges()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func admittedWorkQueuesAfterRetirementAndRestart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Before") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let old = syncEngine.private
        let work = try #require(syncEngine.admit(old))
        syncEngine.stop()
        try await syncEngine.start()
        // Model the deferred retry enqueue of an already-admitted sent-changes callback.
        old.state.add(pendingRecordZoneChanges: [.saveRecord(RemindersList.recordID(for: 1))])
        syncEngine.finish(work)
        try await syncEngine.stopAndDrain()
        try await syncEngine.start()
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.contains(
            .saveRecord(RemindersList.recordID(for: 1))))
        try await syncEngine.sendChanges()
      }
    }
  }

  private final class RetirementLatch: Sendable {
    private let state = LockIsolated(
      (signaled: false, waiters: [CheckedContinuation<Void, Never>]()))
    func wait() async {
      await withCheckedContinuation { continuation in
        state.withValue {
          if $0.signaled { continuation.resume() } else { $0.waiters.append(continuation) }
        }
      }
    }
    func signal() {
      state.withValue {
        $0.signaled = true
        for waiter in $0.waiters { waiter.resume() }
        $0.waiters.removeAll()
      }
    }
  }

  private final class RetirementSQLGate: Sendable {
    let entered = RetirementLatch()
    private let opened = LockIsolated(false)
    private let semaphore = DispatchSemaphore(value: 0)
    func block() {
      guard !opened.value else { return }
      entered.signal()
      #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }
    func open() {
      let wasOpened = opened.withValue {
        defer { $0 = true }
        return $0
      }
      if !wasOpened { semaphore.signal() }
    }
  }
#endif
