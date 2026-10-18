#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtrasTestSupport
  import CustomDump
  import DependenciesTestSupport
  import Foundation
  import InlineSnapshotTesting
  import OrderedCollections
  @testable import SQLiteData
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
        #expect(reportedError.context.operationKind == .fetchedRecordDeletion)
        #expect(reportedError.context.disposition == .terminalDroppedOrReconciled)
        #expect(reportedError.context.tableName == Parent.tableName)
        #expect(reportedError.context.recordType == Parent.tableName)
        #expect(reportedError.context.isRemoteDelete)
        #expect(String(describing: reportedError.error).contains("blocked parent delete"))

        try await userDatabase.read { db in
          try #expect(Parent.find(1).fetchOne(db) != nil)
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func fetchedRecordApplicationFailureIsReported() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.write { db in
          try #sql(
            """
            CREATE TRIGGER prevent_list_update
            BEFORE UPDATE ON remindersLists
            BEGIN
              SELECT RAISE(ABORT, 'blocked fetched record application');
            END
            """
          )
          .execute(db)
        }

        let remoteRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        remoteRecord.setValue("Remote", forKey: "title", at: now + 1)
        try await syncEngine.modifyRecords(scope: .private, saving: [remoteRecord]).notify()

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.last })
        #expect(reportedError.context.operationKind == .fetchedRecordApplication)
        #expect(reportedError.context.disposition == .terminalDroppedOrReconciled)
        #expect(reportedError.context.recordType == RemindersList.tableName)
        #expect(
          String(describing: reportedError.error).contains("blocked fetched record application"))
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Local")
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func cancelledFetchedRecordApplicationsAreRetried() async throws {
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

        let cancelledFetch = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          await modifications.notify()
        }
        await cancelledFetch.value

        #expect(delegate.reportedErrors.withValue(\.count) == 1)
        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect(reportedError.error is CancellationError)
        #expect(reportedError.context.operationKind == .fetchedRecordApplication)
        #expect(reportedError.context.disposition == .transientPendingRetry)
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == 2)
        }

        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote 1")
          try #expect(RemindersList.find(2).fetchOne(db)?.title == "Remote 2")
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == 0)
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
        #expect(reportedError.context.operationKind == .sentRecordSave)
        #expect(reportedError.context.disposition == .recoveredAndRetried)
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
        #expect(reportedError.context.operationKind == .sentRecordSave)
        #expect(reportedError.context.disposition == .terminalDroppedOrReconciled)
        #expect(reportedError.context.recordType == Reminder.tableName)
        #expect(reportedError.context.isLocalSaveFailure)
        let durableFailure = try await syncEngine.metadatabase.read { db in
          try DurableRecordZoneFailure
            .find(Reminder.recordID(for: 1), action: DurableRecordZoneFailure.saveAction)
            .fetchOne(db)
        }
        #expect(durableFailure?.isTerminal == true)
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
        #expect(reportedError.context.operationKind == .sentRecordSave)
        #expect(reportedError.context.disposition == .terminalDroppedOrReconciled)
        #expect(reportedError.context.recordType == RemindersList.tableName)
        #expect(reportedError.context.isLocalSaveFailure)
        syncEngine.private.state.assertPendingDatabaseChanges([])
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func userDeletedZoneRecoveryOnlyUploadsLaterExplicitEdit() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Previously edited")
            RemindersList(id: 2, title: "Untouched")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Rejected edit" }.execute(db)
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: .userDeletedZone
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        await signIn()
        syncEngine.private.state.assertPendingRecordZoneChanges([])
        syncEngine.private.state.assertPendingDatabaseChanges([.saveZone(syncEngine.defaultZone)])

        syncEngine.stop()
        let relaunchedSyncEngine = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          delegate: syncEngineDelegate,
          tables: syncEngine.tables,
          privateTables: syncEngine.privateTables
        )
        relaunchedSyncEngine.private.state.assertPendingRecordZoneChanges([])
        let pendingDatabaseChanges = relaunchedSyncEngine.private.state.pendingDatabaseChanges
        #expect(pendingDatabaseChanges.count == 1)
        if case .saveZone(let zone) = pendingDatabaseChanges.first {
          #expect(zone.zoneID == relaunchedSyncEngine.defaultZone.zoneID)
        } else {
          Issue.record("Expected the default zone to be recreated after an explicit later edit.")
        }
        relaunchedSyncEngine.private.state.remove(
          pendingDatabaseChanges: pendingDatabaseChanges
        )

        try await userDatabase.userWrite { db in
          try RemindersList.find(2).update { $0.title = "Explicit later edit" }.execute(db)
        }
        #expect(
          relaunchedSyncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 2))
          ]
        )
        relaunchedSyncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 2),
          with: .zoneNotFound
        )
        try await relaunchedSyncEngine.processPendingRecordZoneChanges(scope: .private)
        relaunchedSyncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 2))
        ])
        let recreatedZoneChanges = relaunchedSyncEngine.private.state.pendingDatabaseChanges
        #expect(recreatedZoneChanges.count == 1)
        if case .saveZone(let zone) = recreatedZoneChanges.first {
          #expect(zone.zoneID == relaunchedSyncEngine.defaultZone.zoneID)
        } else {
          Issue.record("Expected zoneNotFound to recreate only the default zone.")
        }
        relaunchedSyncEngine.private.state.remove(
          pendingDatabaseChanges: recreatedZoneChanges
        )
        relaunchedSyncEngine.stop()
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

      @Test
      func failedDeleteTransactionDoesNotApplyPendingStateMutations() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "network")
            RemindersList(id: 2, title: "reference")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          try RemindersList.find(2).delete().execute(db)
        }
        try await syncEngine.metadatabase.write { db in
          try #sql(
            """
            CREATE TRIGGER fail_unsynced_insert
            BEFORE INSERT ON sqlitedata_icloud_unsyncedRecordIDs
            BEGIN
              SELECT RAISE(ABORT, 'forced failed-delete transaction rollback');
            END
            """
          )
          .execute(db)
        }
        syncEngine.private.database.failNextDelete(
          for: RemindersList.recordID(for: 1),
          with: .networkFailure
        )
        syncEngine.private.database.failNextDelete(
          for: RemindersList.recordID(for: 2),
          with: .referenceViolation
        )

        try await withKnownIssue {
          try await syncEngine.processPendingRecordZoneChanges(
            scope: .private,
            forceAtomicByZone: false
          )
        } matching: { issue in
          issue.description.contains("forced failed-delete transaction rollback")
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
        let unsyncedCount = try await syncEngine.metadatabase.read { db in
          try UnsyncedRecordID.count().fetchOne(db)
        }
        #expect(unsyncedCount == 0)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func terminalLocalDeleteFailureIsReported() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "delete-me")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        syncEngine.private.database.failNextDelete(
          for: RemindersList.recordID(for: 1),
          with: .serverRejectedRequest
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let remoteRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        remoteRecord.setValue("remote update", forKey: "title", at: now + 1)
        try await syncEngine.modifyRecords(scope: .private, saving: [remoteRecord]).notify()

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db) == nil)
        }
        let durableFailure = try await syncEngine.metadatabase.read { db in
          try DurableRecordZoneFailure
            .find(
              RemindersList.recordID(for: 1),
              action: DurableRecordZoneFailure.deleteAction
            )
            .fetchOne(db)
        }
        #expect(durableFailure?.isTerminal == true)

        let reportedError = try #require(delegate.reportedErrors.withValue { $0.first })
        #expect((reportedError.error as? CKError)?.code == .serverRejectedRequest)
        #expect(reportedError.context.operation == "handleSentRecordZoneChanges.deleteRecords")
        #expect(reportedError.context.operationKind == .sentRecordDelete)
        #expect(reportedError.context.disposition == .terminalDroppedOrReconciled)
        #expect(reportedError.context.tableName == RemindersList.tableName)
        #expect(reportedError.context.recordType == RemindersList.tableName)
        #expect(reportedError.context.isLocalDeleteFailure)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func permanentlyRejectedSaveRetriesOnlyOnce() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Original") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Updated" }.execute(db)
        }

        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: .serverRejectedRequest
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )

        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: .serverRejectedRequest
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        syncEngine.private.state.assertPendingRecordZoneChanges([])

        let failure = try await syncEngine.metadatabase.read { db in
          try DurableRecordZoneFailure
            .find(
              RemindersList.recordID(for: 1),
              action: DurableRecordZoneFailure.saveAction
            )
            .fetchOne(db)
        }
        #expect(failure?.attemptCount == 2)
        #expect(failure?.isTerminal == true)
        let dispositions = delegate.reportedErrors.withValue { $0.map(\.context.disposition) }
        #expect(dispositions == [.recoveredAndRetried, .terminalDroppedOrReconciled])
      }

      @Test(
        $syncEngineDelegate.set(ErrorReportingDelegate()),
        arguments: [CKError.Code.quotaExceeded, .limitExceeded]
      )
      func quotaAndLimitExceededSavesRetryAfterBackoff(errorCode: CKError.Code) async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Original") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Updated" }.execute(db)
        }
        syncEngine.private.database.failNextSave(
          for: RemindersList.recordID(for: 1),
          with: errorCode
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        syncEngine.private.state.assertPendingRecordZoneChanges([])
        #expect(
          delegate.reportedErrors.withValue { $0.last?.context.disposition }
            == .transientPendingRetry
        )

        await Task.yield()
        await testClock.advance(by: .seconds(30))
        await Task.yield()
        // The retry is admitted before its asynchronous durable-failure read. Wait for that
        // work instead of assuming a single executor yield also completes the database hop.
        _ = try await syncEngine.waitForSettlement()
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let serverRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        #expect(serverRecord.encryptedValues["title"] as? String == "Updated")
        let failureCount = try await syncEngine.metadatabase.read { db in
          try DurableRecordZoneFailure.count().fetchOne(db)
        }
        #expect(failureCount == 0)
      }

      @Test(
        FreshFetchErrorDelegate(),
        arguments: [CKDatabase.Scope.private, .shared],
        [CKError.Code.networkFailure, .quotaExceeded, .notAuthenticated, .partialFailure]
      )
      func fetchZoneErrorRetainsOriginalErrorAndContext(
        scope: CKDatabase.Scope, code: CKError.Code
      ) async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let engine = syncEngine.syncEngine(for: scope)
        let zoneID = CKRecordZone.ID(zoneName: "failed-fetch", ownerName: "owner")
        let recordID = CKRecord.ID(recordName: "failed-record", zoneID: zoneID)
        let error = CKError(
          code,
          userInfo: [
            CKErrorRetryAfterKey: 17,
            CKPartialErrorsByItemIDKey: [recordID: CKError(.networkUnavailable)],
          ]
        )

        await syncEngine.handleEvent(
          .willFetchRecordZoneChanges(zoneID: zoneID), syncEngine: engine)
        #expect(syncEngine.isFetchingChanges)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneID, error: error), syncEngine: engine
        )

        let reports = delegate.reportedErrors.value
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect((report.error as NSError).isEqual(error as NSError))
        #expect((report.error as NSError).userInfo[CKErrorRetryAfterKey] as? Int == 17)
        let partialErrors =
          (report.error as NSError).userInfo[CKPartialErrorsByItemIDKey]
          as? [CKRecord.ID: CKError]
        #expect(partialErrors?[recordID]?.code == .networkUnavailable)
        #expect(report.context.operationKind == .fetchRecordZoneChanges)
        #expect(report.context.operation == SyncEngineOperation.fetchRecordZoneChanges.rawValue)
        #expect(report.context.databaseScope == scope)
        #expect(report.context.zoneID == zoneID)
        #expect(report.context.disposition == nil)
        #expect(report.context.tableName == nil)
        #expect(report.context.recordType == nil)
        #expect(!report.context.isRemoteDelete)
        #expect(!report.context.isLocalSaveFailure)
        #expect(!report.context.isLocalDeleteFailure)
        #expect(!syncEngine.isFetchingChanges)
      }

      @Test(
        FreshFetchErrorDelegate(),
        arguments: [CKDatabase.Scope.private, .shared]
      )
      func successfulFetchZoneEventDoesNotReportError(scope: CKDatabase.Scope) async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let engine = syncEngine.syncEngine(for: scope)
        let zoneID = CKRecordZone.ID(zoneName: "successful-fetch")
        await syncEngine.handleEvent(
          .willFetchRecordZoneChanges(zoneID: zoneID), syncEngine: engine)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneID, error: nil), syncEngine: engine
        )
        #expect(delegate.reportedErrors.value.isEmpty)
        #expect(!syncEngine.isFetchingChanges)
      }

      @Test($syncEngineDelegate.set(SuspendedFetchErrorDelegate()))
      func fetchZoneErrorAwaitsDelegateBeforeBecomingIdle() async throws {
        let delegate = try #require(syncEngineDelegate as? SuspendedFetchErrorDelegate)
        let engine = syncEngine.private
        let zoneID = CKRecordZone.ID(zoneName: "suspended-fetch")
        await syncEngine.handleEvent(
          .willFetchRecordZoneChanges(zoneID: zoneID), syncEngine: engine)
        let finished = LockIsolated(false)
        let event = Task {
          await syncEngine.handleEvent(
            .didFetchRecordZoneChanges(zoneID: zoneID, error: CKError(.networkFailure)),
            syncEngine: engine
          )
          finished.setValue(true)
        }
        await delegate.entered.wait()
        #expect(syncEngine.isFetchingChanges)
        #expect(!finished.value)
        delegate.release.signal()
        await event.value
        #expect(delegate.finished.value)
        #expect(!syncEngine.isFetchingChanges)
      }

      @Test(
        FreshFetchErrorDelegate(),
        arguments: [CKDatabase.Scope.private, .shared], [false, true]
      )
      func explicitFetchReportsAndRethrowsOriginalError(
        scope: CKDatabase.Scope, cancellation: Bool
      ) async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let original: any Error =
          cancellation
          ? CancellationError()
          : NSError(domain: "fetch-test", code: 42, userInfo: ["detail": "original"])
        let fetch: FetchErrorSyncEngine.Fetch = { engine, _ in
          if engine.database.databaseScope == scope { throw original }
        }
        try await withFetchErrorEngines(privateFetch: fetch, sharedFetch: fetch) {
          do {
            try await syncEngine.fetchChanges()
            Issue.record("Expected fetchChanges to throw")
          } catch {
            #expect((error as NSError).isEqual(original as NSError))
            if cancellation {
              #expect(error is CancellationError)
            } else {
              #expect(error as NSError === original as NSError)
            }
          }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect((report.error as NSError).isEqual(original as NSError))
        if cancellation { #expect(report.error is CancellationError) }
        #expect(report.context.operationKind == .fetchChanges)
        #expect(report.context.operation == SyncEngineOperation.fetchChanges.rawValue)
        #expect(report.context.databaseScope == scope)
        #expect(report.context.zoneID == nil)
        #expect(report.context.disposition == nil)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func cancelledExplicitFetchReportsCancellationFromBothEngines() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let privateEntered = FetchErrorLatch()
        let sharedEntered = FetchErrorLatch()
        let release = FetchErrorLatch()
        try await withFetchErrorEngines(
          privateFetch: { _, _ in
            privateEntered.signal()
            await release.wait()
            try Task.checkCancellation()
          },
          sharedFetch: { _, _ in
            sharedEntered.signal()
            await release.wait()
            try Task.checkCancellation()
          }
        ) {
          let fetch = Task { try await syncEngine.fetchChanges() }
          await privateEntered.wait()
          await sharedEntered.wait()
          fetch.cancel()
          release.signal()
          await #expect(throws: CancellationError.self) { try await fetch.value }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.count == 2)
        for scope in [CKDatabase.Scope.private, .shared] {
          let report = try #require(reports.first { $0.context.databaseScope == scope })
          #expect(report.error is CancellationError)
          #expect(report.context.operationKind == .fetchChanges)
          #expect(report.context.zoneID == nil)
        }
      }

      @Test($syncEngineDelegate.set(SuspendedFetchErrorDelegate()))
      func explicitFetchAwaitsDelegateBeforeRethrowingWithoutAnEvent() async throws {
        let delegate = try #require(syncEngineDelegate as? SuspendedFetchErrorDelegate)
        let error = NSError(domain: "suspended-explicit-fetch", code: 1)
        let finished = LockIsolated(false)
        try await withFetchErrorEngines(privateFetch: { _, _ in throw error }) {
          let fetch = Task {
            defer { finished.setValue(true) }
            try await syncEngine.fetchChanges()
          }
          await delegate.entered.wait()
          #expect(!finished.value)
          #expect(!delegate.finished.value)
          delegate.release.signal()
          do {
            try await fetch.value
            Issue.record("Expected fetchChanges to throw")
          } catch let caught {
            #expect(caught as NSError === error)
          }
          #expect(delegate.finished.value)
          #expect(delegate.reportCount.value == 1)
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func explicitFetchRunsBothScopesConcurrentlyAndReportsBothFailures() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let privateEntered = FetchErrorLatch()
        let sharedEntered = FetchErrorLatch()
        let privateError = NSError(domain: "private-fetch", code: 1)
        let sharedError = NSError(domain: "shared-fetch", code: 2)
        try await withFetchErrorEngines(
          privateFetch: { _, _ in
            privateEntered.signal()
            await sharedEntered.wait()
            throw privateError
          },
          sharedFetch: { _, _ in
            sharedEntered.signal()
            await privateEntered.wait()
            throw sharedError
          }
        ) {
          do {
            try await syncEngine.fetchChanges()
            Issue.record("Expected fetchChanges to throw")
          } catch {
            #expect(
              (error as NSError).isEqual(privateError) || (error as NSError).isEqual(sharedError)
            )
          }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.count == 2)
        for (scope, error) in [(CKDatabase.Scope.private, privateError), (.shared, sharedError)] {
          let report = try #require(reports.first { $0.context.databaseScope == scope })
          #expect((report.error as NSError).isEqual(error))
          #expect(report.context.operationKind == .fetchChanges)
          #expect(report.context.zoneID == nil)
        }
      }

      @Test(
        FreshFetchErrorDelegate(),
        arguments: [CKDatabase.Scope.private, .shared], [false, true]
      )
      func fetchDeduplicatesOnlyEqualErrorsWithinTheSameAttempt(
        scope: CKDatabase.Scope, wrapsEventError: Bool
      ) async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let zoneID = CKRecordZone.ID(zoneName: "deduplicated-fetch")
        let eventError = CKError(.networkFailure, userInfo: [CKErrorRetryAfterKey: 12])
        // Independently constructed equal NSError values must deduplicate, not just identity.
        let thrownError =
          wrapsEventError
          ? NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: eventError])
          : NSError(
            domain: CKErrorDomain, code: CKError.networkFailure.rawValue,
            userInfo: [CKErrorRetryAfterKey: 12]
          )
        #expect(thrownError.isEqual(eventError as NSError) == !wrapsEventError)
        let attempts = LockIsolated(0)
        let fetch: FetchErrorSyncEngine.Fetch = { engine, _ in
          guard engine.database.databaseScope == scope else { return }
          let attempt = attempts.withValue {
            $0 += 1
            return $0
          }
          if attempt == 1 {
            await engine.emit(.didFetchRecordZoneChanges(zoneID: zoneID, error: eventError))
          }
          throw thrownError
        }
        try await withFetchErrorEngines(privateFetch: fetch, sharedFetch: fetch) {
          for attempt in 1...2 {
            do {
              try await syncEngine.fetchChanges()
              Issue.record("Expected fetchChanges to throw")
            } catch {
              #expect((error as NSError).isEqual(thrownError))
            }
            #expect(delegate.reportedErrors.value.count == attempt + (wrapsEventError ? 1 : 0))
          }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.first?.context.operationKind == .fetchRecordZoneChanges)
        #expect(reports.first?.context.zoneID == zoneID)
        #expect(reports.last?.context.operationKind == .fetchChanges)
        #expect(reports.allSatisfy { $0.context.databaseScope == scope })
        #expect((reports.last?.error as NSError?)?.isEqual(thrownError) == true)
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func distinctFetchEventAndThrownErrorsAreBothReported() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let eventError = CKError(.networkFailure)
        let thrownError = CKError(.notAuthenticated)
        let zoneID = CKRecordZone.ID(zoneName: "distinct-errors")
        try await withFetchErrorEngines(
          privateFetch: { engine, _ in
            await engine.emit(.didFetchRecordZoneChanges(zoneID: zoneID, error: eventError))
            throw thrownError
          }
        ) {
          do {
            try await syncEngine.fetchChanges()
            Issue.record("Expected fetchChanges to throw")
          } catch {
            #expect((error as NSError).isEqual(thrownError as NSError))
          }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.count == 2)
        #expect((reports.first?.error as? CKError)?.code == .networkFailure)
        #expect(reports.first?.context.operationKind == .fetchRecordZoneChanges)
        #expect(reports.first?.context.zoneID == zoneID)
        #expect((reports.last?.error as? CKError)?.code == .notAuthenticated)
        #expect(reports.last?.context.operationKind == .fetchChanges)
        #expect(reports.last?.context.zoneID == nil)
        #expect(reports.allSatisfy { $0.context.databaseScope == .private })
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func equalEventFromOtherEngineDoesNotSuppressExplicitFailure() async throws {
        let delegate = try #require(syncEngineDelegate as? ErrorReportingDelegate)
        let eventDelivered = FetchErrorLatch()
        let sharedEntered = FetchErrorLatch()
        let error = CKError(.networkFailure)
        let zoneID = CKRecordZone.ID(zoneName: "other-engine")
        try await withFetchErrorEngines(
          privateFetch: { engine, _ in
            await sharedEntered.wait()
            await engine.emit(.didFetchRecordZoneChanges(zoneID: zoneID, error: error))
            eventDelivered.signal()
          },
          sharedFetch: { _, _ in
            sharedEntered.signal()
            await eventDelivered.wait()
            throw error
          }
        ) {
          await #expect(throws: CKError.self) { try await syncEngine.fetchChanges() }
        }
        let reports = delegate.reportedErrors.value
        #expect(reports.count == 2)
        #expect(reports.first?.context.databaseScope == .private)
        #expect(reports.first?.context.operationKind == .fetchRecordZoneChanges)
        #expect(reports.last?.context.databaseScope == .shared)
        #expect(reports.last?.context.operationKind == .fetchChanges)
      }

      @Test($syncEngineDelegate.set(SuspendedFetchErrorDelegate()))
      func explicitFetchAwaitsRacingDuplicateEventDelivery() async throws {
        let delegate = try #require(syncEngineDelegate as? SuspendedFetchErrorDelegate)
        let throwing = FetchErrorLatch()
        let eventTask = LockIsolated<Task<Void, Never>?>(nil)
        let finished = LockIsolated(false)
        let error = CKError(.networkFailure)
        try await withMainSerialExecutor {
          try await withFetchErrorEngines(
            privateFetch: { engine, _ in
              eventTask.setValue(
                Task {
                  await engine.emit(
                    .didFetchRecordZoneChanges(
                      zoneID: CKRecordZone.ID(zoneName: "racing-fetch"), error: error
                    )
                  )
                })
              await delegate.entered.wait()
              throwing.signal()
              throw error
            }
          ) {
            let fetch = Task {
              defer { finished.setValue(true) }
              try await syncEngine.fetchChanges()
            }
            await throwing.wait()
            await Task.yield()
            #expect(!finished.value)
            #expect(!delegate.finished.value)
            delegate.release.signal()
            await #expect(throws: CKError.self) { try await fetch.value }
            await eventTask.value?.value
            #expect(delegate.finished.value)
            #expect(delegate.reportCount.value == 1)
          }
        }
      }

      @Test
      func errorContextInitializersRemainSourceCompatible() {
        let legacy = SyncEngineErrorContext(operation: "custom-operation", tableName: "items")
        #expect(legacy.operation == "custom-operation")
        #expect(legacy.operationKind == nil)
        #expect(legacy.tableName == "items")
        let typed = SyncEngineErrorContext(
          operation: .sentRecordSave, disposition: .recoveredAndRetried,
          recordType: "items", isLocalSaveFailure: true
        )
        #expect(typed.operation == SyncEngineOperation.sentRecordSave.rawValue)
        #expect(typed.operationKind == .sentRecordSave)
        #expect(typed.disposition == .recoveredAndRetried)
        #expect(typed.isLocalSaveFailure)
        let fetch = SyncEngineErrorContext(operation: .fetchChanges)
        for context in [legacy, typed, fetch] {
          #expect(context.databaseScope == nil)
          #expect(context.zoneID == nil)
        }
        #expect(fetch.disposition == nil)
        let zoneID = CKRecordZone.ID(zoneName: "context")
        let scoped = SyncEngineErrorContext(
          operation: SyncEngineOperation.fetchRecordZoneChanges.rawValue,
          databaseScope: .shared, zoneID: zoneID
        )
        #expect(scoped.operationKind == .fetchRecordZoneChanges)
        #expect(scoped.databaseScope == .shared)
        #expect(scoped.zoneID == zoneID)
      }

      @Test($syncEngineDelegate.set(DefaultImplementationDelegate()))
      func defaultErrorDelegateDoesNotChangeFetchFailureBehavior() async throws {
        let error = CKError(.notAuthenticated)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: syncEngine.defaultZone.zoneID, error: error),
          syncEngine: syncEngine.private
        )
        try await withFetchErrorEngines(privateFetch: { _, _ in throw error }) {
          await #expect(throws: CKError.self) { try await syncEngine.fetchChanges() }
        }
      }

      private func withFetchErrorEngines(
        privateFetch: @escaping FetchErrorSyncEngine.Fetch = { _, _ in },
        sharedFetch: @escaping FetchErrorSyncEngine.Fetch = { _, _ in },
        operation: () async throws -> Void
      ) async rethrows {
        let originalPrivate = syncEngine.private
        let originalShared = syncEngine.shared
        let originalEngines = syncEngine.syncEngines.withValue {
          let original = $0
          $0 = SyncEngines(
            private: FetchErrorSyncEngine(base: originalPrivate, fetch: privateFetch),
            shared: FetchErrorSyncEngine(base: originalShared, fetch: sharedFetch)
          )
          return original
        }
        defer { syncEngine.syncEngines.withValue { $0 = originalEngines } }
        try await operation()
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
    let zoneDeletions = LockIsolated<[SyncEngineZoneDeletionContext]>([])

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

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      willDeleteLocalRecords context: SyncEngineZoneDeletionContext
    ) async {
      zoneDeletions.withValue { $0.append(context) }
    }
  }

  final class DefaultImplementationDelegate: SyncEngineDelegate {
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class FetchErrorSyncEngine: SyncEngineProtocol {
    typealias Fetch =
      @Sendable (FetchErrorSyncEngine, CKSyncEngine.FetchChangesOptions) async throws -> Void
    let base: MockSyncEngine
    let fetch: Fetch
    var database: MockCloudDatabase { base.database }
    var state: MockSyncEngineState { base.state }

    init(base: MockSyncEngine, fetch: @escaping Fetch) {
      self.base = base
      self.fetch = fetch
    }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
      try await fetch(self, options)
    }

    func emit(_ event: SyncEngine.Event) async {
      await base.parentSyncEngine.handleEvent(event, syncEngine: self)
    }

    func cancelOperations() async { await base.cancelOperations() }

    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
      try await base.sendChanges(options)
    }

    func recordZoneChangeBatch(
      pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
      recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await base.recordZoneChangeBatch(
        pendingChanges: pendingChanges, recordProvider: recordProvider)
    }
  }

  // TaskLocal.set stores a single instance, shared by all parameterized cases.
  private struct FreshFetchErrorDelegate: TestTrait, TestScoping {
    func provideScope(
      for test: Test,
      testCase: Test.Case?,
      performing function: @concurrent () async throws -> Void
    ) async throws {
      try await $syncEngineDelegate.withValue(ErrorReportingDelegate(), operation: function)
    }
  }

  private final class FetchErrorLatch: Sendable {
    private struct State {
      var signaled = false
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())

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

  private final class SuspendedFetchErrorDelegate: SyncEngineDelegate {
    let entered = FetchErrorLatch()
    let release = FetchErrorLatch()
    let finished = LockIsolated(false)
    let reportCount = LockIsolated(0)

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {
      reportCount.withValue { $0 += 1 }
      entered.signal()
      await release.wait()
      finished.setValue(true)
    }
  }
#endif
