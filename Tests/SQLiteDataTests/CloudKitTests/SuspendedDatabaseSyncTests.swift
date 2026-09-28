#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation
  import GRDB
  import SQLiteData
  import Testing
  import TestLocals

  /// Apps that post `Database.suspendNotification` when backgrounded (as GRDB recommends)
  /// keep receiving CloudKit changes while the database is suspended. Writes then fail with
  /// `SQLITE_ABORT` ("Database is suspended") or `SQLITE_INTERRUPT`. Those changes must be
  /// applied once the database resumes instead of being dropped, because CKSyncEngine has
  /// already advanced its change token and will not deliver them again.
  ///
  /// Serialized: suspension notifications are process-wide.
  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized, $observesSuspensionNotifications.set(true))
    final class SuspendedDatabaseSyncTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func fetchedRecordsReceivedWhileSuspendedAreAppliedAfterResume() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Local 1")
            RemindersList(id: 2, title: "Local 2")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let remoteRecords = try [1, 2].map { id in
          let record = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: id)
          )
          record.setValue("Remote \(id)", forKey: "title", at: now + 1)
          return record
        }
        let modifications = try syncEngine.modifyRecords(
          scope: .private,
          saving: remoteRecords
        )

        try await whileSuspended {
          await modifications.notify()
        }

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote 1")
          try #expect(RemindersList.find(2).fetchOne(db)?.title == "Remote 2")
        }
        #expect(
          delegate.reportedErrors.withValue {
            $0.filter { $0.context.disposition == .terminalDroppedOrReconciled }
          }
          .isEmpty
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func remoteDeletionsReceivedWhileSuspendedAreAppliedAfterResume() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Doomed")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let deletion = try syncEngine.modifyRecords(
          scope: .private,
          deleting: [RemindersList.recordID(for: 1)]
        )

        try await whileSuspended {
          await deletion.notify()
        }

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db) == nil)
        }
        #expect(
          delegate.reportedErrors.withValue {
            $0.filter { $0.context.disposition == .terminalDroppedOrReconciled }
          }
          .isEmpty
        )
      }

      /// A local edit is sent while another device has changed the same record. The server's
      /// `.serverRecordChanged` copy must be merged locally and the merged record re-sent. Before
      /// the fix, the merge write failed while suspended and the local edit was never uploaded.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func sentSaveConflictWhileSuspendedIsMergedAfterResume() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "List")
            Reminder(id: 1, title: "Local", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // Another device renames the reminder; this device has not fetched it.
        let remote = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        remote.setValue("Remote", forKey: "title", at: now + 1)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [remote])

        try await withDependencies {
          $0.currentTime.now += 30
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.isCompleted = true }.execute(db)
          }
        }

        try await whileSuspended {
          try? await self.syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          let reminder = try #require(try Reminder.find(1).fetchOne(db))
          #expect(reminder.title == "Remote")
          #expect(reminder.isCompleted)
        }
        let server = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        #expect(server.encryptedValues["title"] as? String == "Remote")
        #expect(server.encryptedValues["isCompleted"] as? Int64 == 1)
        #expect(
          delegate.reportedErrors.withValue {
            $0.filter { $0.context.disposition == .terminalDroppedOrReconciled }
          }
          .isEmpty
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func nonSuspensionAbortsAndRepeatedInterruptsStillFail() async throws {
        let attempts = LockIsolated(0)
        await #expect(throws: DatabaseError.self) {
          try await self.userDatabase.write { _ in
            attempts.withValue { $0 += 1 }
            throw DatabaseError(resultCode: .SQLITE_ABORT, message: "callback requested abort")
          }
        }
        #expect(attempts.value == 1)

        attempts.setValue(0)
        await #expect(throws: DatabaseError.self) {
          try await self.userDatabase.write { _ in
            attempts.withValue { $0 += 1 }
            throw DatabaseError(resultCode: .SQLITE_INTERRUPT)
          }
        }
        #expect(attempts.value == 4)
      }

      /// Starts `operation` while the database is suspended, waits until one of its writes
      /// has actually been rejected by suspension, checks it is still waiting (the pre-fix
      /// code finished here, having dropped the changes), then resumes.
      private func whileSuspended(
        _ operation: @escaping @Sendable () async -> Void
      ) async throws {
        let attemptsBefore = UserDatabase.suspendedWriteAttempts.value
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        let finished = LockIsolated(false)
        let task = Task {
          await operation()
          finished.setValue(true)
        }
        defer {
          NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while UserDatabase.suspendedWriteAttempts.value == attemptsBefore,
          !finished.value,
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
          UserDatabase.suspendedWriteAttempts.value > attemptsBefore,
          "no write was attempted while the database was suspended"
        )
        #expect(!finished.value, "sync event finished while the database was suspended")
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        await task.value
      }
    }
  }
#endif
