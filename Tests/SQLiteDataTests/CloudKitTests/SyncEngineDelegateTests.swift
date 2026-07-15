#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtrasTestSupport
  import CustomDump
  import DependenciesTestSupport
  import Foundation
  import InlineSnapshotTesting
  import OrderedCollections
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    final class SyncEngineDelegateTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)

      @Test($syncEngineDelegate.set(MyDelegate()))
      func accountChanged() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        await signOut()

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          ┌─────────────────────┐
          │ RemindersList(      │
          │   id: 1,            │
          │   title: "Personal" │
          │ )                   │
          └─────────────────────┘
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     title: "Personal"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "My stuff" }.execute(db)
        }

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          ┌─────────────────────┐
          │ RemindersList(      │
          │   id: 1,            │
          │   title: "My stuff" │
          │ )                   │
          └─────────────────────┘
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     title: "Personal"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        await signIn()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func reportedError_RemoteDeleteForeignKeyFailure() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 1)
          }
          try #sql(
            """
            CREATE TRIGGER prevent_parent_delete
            BEFORE DELETE ON parents
            BEGIN
              SELECT RAISE(ABORT, 'blocked parent delete');
            END
            """
          )
          .execute(db)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withKnownIssue {
          try await syncEngine.modifyRecords(
            scope: .private,
            deleting: [Parent.recordID(for: 1)]
          )
          .notify()
        } matching: { issue in
          issue.description.contains("blocked parent delete")
        }

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect(reportedError.context.operation == "handleFetchedRecordZoneChanges.deleteRecords")
        #expect(reportedError.context.tableName == Parent.tableName)
        #expect(reportedError.context.recordType == Parent.tableName)
        #expect(reportedError.context.isRemoteDelete)
        #expect(String(describing: reportedError.error).contains("blocked parent delete"))

        try await userDatabase.read { db in
          try #expect(Parent.find(1).fetchOne(db) != nil)
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func reportedError_RejectedLocalRelationshipSaveIsRecovered() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Fallback")
            RemindersList(id: 2, title: "Restored")
            Reminder(id: 1, title: "Original", remindersListID: 1)
            Tag(title: "relationship-recovery-row")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.remindersListID = 2 }.execute(db)
            try Tag.find("relationship-recovery-row").delete().execute(db)
          }
        }

        syncEngine.private.database.failNextSave(
          for: Reminder.recordID(for: 1),
          with: .serverRejectedRequest
        )
        try await syncEngine.processPendingRecordZoneChanges(
          scope: .private,
          forceAtomicByZone: false
        )

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          let remoteReminder = try syncEngine.private.database.record(
            for: Reminder.recordID(for: 1)
          )
          remoteReminder.setValue("Remote title", forKey: "title", at: now)
          try await syncEngine.modifyRecords(scope: .private, saving: [remoteReminder]).notify()
        }

        let localReminder = try await userDatabase.read { db in
          let reminder = try Reminder.find(1).fetchOne(db)
          return try #require(reminder)
        }
        #expect(localReminder.remindersListID == 2)
        #expect(localReminder.title == "Remote title")

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let serverReminder = try syncEngine.private.database.record(
          for: Reminder.recordID(for: 1)
        )
        #expect(serverReminder.parent?.recordID == RemindersList.recordID(for: 2))
        #expect(throws: CKError.self) {
          try syncEngine.private.database.record(
            for: Tag.recordID(for: "relationship-recovery-row")
          )
        }

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect((reportedError.error as? CKError)?.code == .serverRejectedRequest)
        #expect(reportedError.context.operation == "handleSentRecordZoneChanges.saveRecords")
        #expect(reportedError.context.tableName == Reminder.tableName)
        #expect(reportedError.context.recordType == Reminder.tableName)
        #expect(reportedError.context.isLocalSaveFailure)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func rejectedLocalSaveWithoutServerRecordPreservesMergeBaseline() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Fallback")
            RemindersList(id: 2, title: "Restored")
            Reminder(id: 1, title: "Original", remindersListID: 1)
            Tag(title: "relationship-recovery-row")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.remindersListID = 2 }.execute(db)
            try Tag.find("relationship-recovery-row").delete().execute(db)
          }
        }

        syncEngine.private.database.failNextSave(
          for: Reminder.recordID(for: 1),
          with: .serverRejectedRequest,
          includesServerRecord: false
        )
        try await syncEngine.processPendingRecordZoneChanges(
          scope: .private,
          forceAtomicByZone: false
        )

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          let remoteReminder = try syncEngine.private.database.record(
            for: Reminder.recordID(for: 1)
          )
          remoteReminder.setValue("Remote title", forKey: "title", at: now)
          try await syncEngine.modifyRecords(scope: .private, saving: [remoteReminder]).notify()
        }

        let localReminder = try await userDatabase.read { db in
          let reminder = try Reminder.find(1).fetchOne(db)
          return try #require(reminder)
        }
        #expect(localReminder.remindersListID == 2)
        #expect(localReminder.title == "Remote title")
        #expect(throws: CKError.self) {
          try syncEngine.private.database.record(
            for: Tag.recordID(for: "relationship-recovery-row")
          )
        }

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect((reportedError.error as? CKError)?.code == .serverRejectedRequest)
        #expect(reportedError.context.recordType == Reminder.tableName)
        #expect(reportedError.context.isLocalSaveFailure)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func userDeletedZoneSaveIsReportedWithoutRecreatingZone() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Original")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Updated" }.execute(db)
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: .userDeletedZone
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect((reportedError.error as? CKError)?.code == .userDeletedZone)
        #expect(reportedError.context.recordType == RemindersList.tableName)
        #expect(reportedError.context.isLocalSaveFailure)
        syncEngine.private.state.assertPendingDatabaseChanges([])
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      @Test
      func transientLocalSaveAndDeleteFailuresAreRetried() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Original")
            Tag(title: "delete-me")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Updated" }.execute(db)
          try Tag.find("delete-me").delete().execute(db)
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: .networkFailure
        )
        syncEngine.private.database.failNextDelete(
          for: Tag.recordID(for: "delete-me"),
          with: .networkFailure
        )

        try await syncEngine.processPendingRecordZoneChanges(
          scope: .private,
          forceAtomicByZone: false
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let serverList = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        #expect(serverList.encryptedValues["title"] as? String == "Updated")
        #expect(throws: CKError.self) {
          try syncEngine.private.database.record(for: Tag.recordID(for: "delete-me"))
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func terminalLocalDeleteFailureIsReported() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            Tag(title: "delete-me")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try Tag.find("delete-me").delete().execute(db)
        }
        syncEngine.private.database.failNextDelete(
          for: Tag.recordID(for: "delete-me"),
          with: .serverRejectedRequest
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        _ = try syncEngine.private.database.record(for: Tag.recordID(for: "delete-me"))
        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect((reportedError.error as? CKError)?.code == .serverRejectedRequest)
        #expect(reportedError.context.operation == "handleSentRecordZoneChanges.deleteRecords")
        #expect(reportedError.context.tableName == Tag.tableName)
        #expect(reportedError.context.recordType == Tag.tableName)
        #expect(reportedError.context.isLocalDeleteFailure)
      }

      @Test($syncEngineDelegate.set(DefaultImplementationDelegate()))
      func accountChanged_DefaultImplementation() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        await signOut()

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          (No results)
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          (No results)
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }
    }
  }

  final class MyDelegate: SyncEngineDelegate {
    let wasCalled = LockIsolated(false)
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      wasCalled.withValue { $0 = true }
    }
    deinit {
      guard wasCalled.withValue(\.self)
      else {
        Issue.record("Delegate method 'syncEngine(_:accountChanged:)' was not called.")
        return
      }
    }
  }

  final class ErrorReportingDelegate: SyncEngineDelegate {
    struct ReportedError: Sendable {
      let error: any Error
      let context: SyncEngineErrorContext
    }

    let reportedErrors = LockIsolated<[ReportedError]>([])

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {}

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {
      reportedErrors.withValue { $0.append(ReportedError(error: error, context: context)) }
    }
  }

  final class DefaultImplementationDelegate: SyncEngineDelegate {
  }
#endif
