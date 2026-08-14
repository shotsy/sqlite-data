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
        #expect(String(describing: reportedError.error).contains("blocked fetched record application"))
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

        syncEngine.private.state.changeTag.withValue { $0 = .max }
        try await syncEngine.fetchChanges()

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
#endif
