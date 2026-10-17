#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation
  import GRDB
  @testable import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    final class MaintenanceOriginTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($startImmediately.set(false), arguments: [false, true])
      func unchangedMigrationsSurviveSyncEngineSetup(installedByMigration: Bool) async throws {
        // Capture the application's pre-engine schema, not SyncEngine's additions.
        let schema = try await userDatabase.read { db in
          try String.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'sqlitedata_%'
            ORDER BY rowid
            """)
        }
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("App schema") { db in
          for sql in schema { try db.execute(sql: sql) }
          if installedByMigration { try SQLiteDataMaintenance.install(in: db) }
        }
        do {
          let database = try DatabaseQueue(path: path)
          try migrator.migrate(database)
          let engine = try await SyncEngine(
            container: container, userDatabase: UserDatabase(database: database),
            tables: [SynchronizedTable(for: RemindersList.self)], startImmediately: false
          )
          try await UserDatabase(database: database).write { db in
            try db.execute(sql: "INSERT INTO remindersLists (id) VALUES (42)")
            try SQLiteDataMaintenance.withScope(in: db) {}
          }
          _ = engine
        }
        let reopened = try DatabaseQueue(path: path)
        try migrator.migrate(reopened)
        try await reopened.read { db throws in
          #expect(try Int.fetchOne(db, sql: "SELECT id FROM remindersLists") == 42)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func restoredShareCancelsRootAndShareDeletes(rollback: Bool) async throws {
        let list = RemindersList(id: 1)
        try await userDatabase.userWrite { db in try db.seed { list } }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let shared = try await syncEngine.share(record: list, configure: { _ in })
        try await userDatabase.userWrite { db in
          try db.inSavepoint {
            try RemindersList.find(1).delete().execute(db)
            if !rollback { try db.seed { list } }
            return rollback ? .rollback : .commit
          }
        }
        _ = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(!syncEngine.private.state.pendingRecordZoneChanges.contains(.deleteRecord(shared.share.recordID)))
        #expect(try container.privateCloudDatabase.record(for: shared.share.recordID) is CKShare)
        if !syncEngine.private.state.pendingRecordZoneChanges.isEmpty {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stoppedEngineRestorationKeepsShare() async throws {
        let list = RemindersList(id: 1)
        try await userDatabase.userWrite { db in try db.seed { list } }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let shared = try await syncEngine.share(record: list, configure: { _ in })
        syncEngine.stop()
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          try db.seed { list }
        }
        // Wait for stopped-engine callback tasks to persist both operations before restarting.
        while try await syncEngine.metadatabase.read({ db in
          try PendingRecordZoneChange.count().fetchOne(db) ?? 0
        }) < 3 { await Task.yield() }
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        if !syncEngine.private.state.pendingRecordZoneChanges.isEmpty {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        _ = try container.privateCloudDatabase.record(for: shared.share.recordID)
        _ = try container.privateCloudDatabase.record(for: RemindersList.recordID(for: 1))
        // A late share-only callback must also be cancelled from the durable live-root snapshot.
        syncEngine.private.state.add(pendingRecordZoneChanges: [.deleteRecord(shared.share.recordID)])
        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(batch == nil)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func validationAndPruneUseSameWriterTransaction() async throws {
        let validationReads = LockIsolated(0)
        try await userDatabase.userWrite { db in try db.seed { RemindersList(id: 1) } }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          // A restoration queued before batch preparation must win. Inspect the writer's
          // SQL stream to verify there can no longer be a read/write transaction gap.
          try db.seed { RemindersList(id: 1) }
          db.trace { event in
            if case .statement(let statement) = event,
              statement.sql.contains("SELECT"), statement.sql.contains("sqlitedata_icloud_metadata"),
              statement.sql.contains(" IN "), statement.sql.contains("NOT (")
            {
              validationReads.withValue { $0 += 1 }
              #expect(db.isInsideTransaction)
            }
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db throws in
          db.trace(options: [])
          #expect(validationReads.value == 1)
          #expect(try SyncMetadata.count().fetchOne(db) == 1)
        }
        _ = try container.privateCloudDatabase.record(for: RemindersList.recordID(for: 1))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedValidationDefersRestoredDelete() async throws {
        struct Failure: Error {}
        try await userDatabase.userWrite { db in try db.seed { RemindersList(id: 1) } }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          try db.seed { RemindersList(id: 1) }
          db.add(function: GRDB.DatabaseFunction("fail_validation", argumentCount: 0) { _ in throw Failure() })
          try db.execute(sql: """
            CREATE TEMP VIEW sqlitedata_icloud_metadata AS
            SELECT * FROM sqlitedata_icloud.sqlitedata_icloud_metadata WHERE fail_validation()
            """)
        }
        var batch: CKSyncEngine.RecordZoneChangeBatch?
        await withKnownIssue {
          batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        }
        #expect(batch == nil)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.contains(.deleteRecord(RemindersList.recordID(for: 1))))
        try await userDatabase.userWrite { db in
          try db.execute(sql: "DROP VIEW temp.sqlitedata_icloud_metadata")
          #expect(try SyncMetadata.count().fetchOne(db) == 1)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        _ = try container.privateCloudDatabase.record(for: RemindersList.recordID(for: 1))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedPruneDefersBatchAndPreservesQueue() async throws {
        try await userDatabase.userWrite { db in try db.seed { RemindersList(id: 1) } }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          try db.execute(sql: """
            CREATE TEMP TRIGGER fail_prune BEFORE DELETE ON sqlitedata_icloud_metadata
            BEGIN SELECT RAISE(ABORT, 'injected prune failure'); END
            """)
        }
        var batch: CKSyncEngine.RecordZoneChangeBatch?
        await withKnownIssue {
          batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        }
        #expect(batch == nil)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.contains(.deleteRecord(RemindersList.recordID(for: 1))))
        try await userDatabase.userWrite { db in
          #expect(try SyncMetadata.count().fetchOne(db) == 1)
          try db.execute(sql: "DROP TRIGGER fail_prune")
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletesKeepOriginAndUploadNormally() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1)
            RemindersList(id: 2)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try SQLiteDataMaintenance.withScope(in: db) {
            try RemindersList.find(1).delete().execute(db)
          }
          try RemindersList.find(2).delete().execute(db)
          #expect(try deletionOrigins(db) == ["maintenance", "user"])
          #expect(try SyncMetadata.where(\._isDeleted).count().fetchOne(db) == 2)
        }
        #expect(Set(syncEngine.private.state.pendingRecordZoneChanges) == Set([
          .deleteRecord(RemindersList.recordID(for: 1)),
          .deleteRecord(RemindersList.recordID(for: 2)),
        ]))
        // A fresh connection reads the durable origins, not connection-local state.
        let reopened = try DatabaseQueue(path: syncEngine.metadatabase.path)
        try await reopened.read { db throws in
          #expect(try deletionOrigins(db) == ["maintenance", "user"])
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.metadatabase.read { db throws in
          #expect(try SyncMetadata.count().fetchOne(db) == 0)
        }
        let cloud = container.privateCloudDatabase
        #expect(throws: CKError.self) { try cloud.record(for: RemindersList.recordID(for: 1)) }
        #expect(throws: CKError.self) { try cloud.record(for: RemindersList.recordID(for: 2)) }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func reinsertionReplacesPendingDelete() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1) }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try SQLiteDataMaintenance.withScope(in: db) {
            try RemindersList.find(1).delete().execute(db)
          }
          try db.seed { RemindersList(id: 1, title: "Restored") }
          #expect(try deletionOrigins(db) == ["live"])
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try container.privateCloudDatabase.record(for: RemindersList.recordID(for: 1))
        #expect(record.encryptedValues["title"] as? String == "Restored")
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
          #expect(try deletionOrigins(db) == ["user"])
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($startImmediately.set(false))
      func synchronizedPrimaryKeyChangeIsNotUserOrigin() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1) }
        }
        try await userDatabase.write { db in
          try db.execute(sql: "UPDATE remindersLists SET id = 2 WHERE id = 1")
          #expect(try deletionOrigins(db) == ["legacy", "live"])
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($startImmediately.set(false))
      func primaryKeyChangesAndReinsertion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1) }
          try SQLiteDataMaintenance.withScope(in: db) {
            try db.execute(sql: "UPDATE remindersLists SET id = 2 WHERE id = 1")
          }
          #expect(try deletionOrigins(db) == ["maintenance", "live"])
          try db.execute(sql: "UPDATE remindersLists SET id = 3 WHERE id = 2")
          #expect(try deletionOrigins(db) == ["maintenance", "user", "live"])
          try db.seed { RemindersList(id: 1) }
          #expect(try deletionOrigins(db) == ["live", "user", "live"])
          #expect(try SyncMetadata.find(RemindersList(id: 1).syncMetadataID)
            .select(\._isDeleted).fetchOne(db) == false)
          try RemindersList.find(1).delete().execute(db)
          #expect(try deletionOrigins(db) == ["user", "user", "live"])
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($startImmediately.set(false))
      func thrownScopeAndOuterRollbackRestoreMetadata() async throws {
        struct Failure: Error {}
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1) }
          #expect(throws: Failure.self) {
            try SQLiteDataMaintenance.withScope(in: db) {
              try RemindersList.find(1).delete().execute(db)
              throw Failure()
            }
          }
          #expect(try deletionOrigins(db) == ["live"])
          #expect(try RemindersList.count().fetchOne(db) == 1)
          try db.inSavepoint {
            try SQLiteDataMaintenance.withScope(in: db) {
              try RemindersList.find(1).delete().execute(db)
            }
            #expect(try deletionOrigins(db) == ["maintenance"])
            return .rollback
          }
          #expect(try deletionOrigins(db) == ["live"])
          #expect(try RemindersList.count().fetchOne(db) == 1)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM main.sqlite_master WHERE name = 'sqlitedata_maintenanceContext'") == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($startImmediately.set(false))
      func legacyMigrationRetainsUnknownOriginAcrossReopen() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1) }
          try RemindersList.find(1).delete().execute(db)
        }
        // Recreate the previous released schema and migration ledger on a separate file.
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
          let legacy = try DatabaseQueue(path: path)
          try syncEngine.metadatabase.backup(to: legacy)
          try await legacy.write { db in
            try db.execute(sql: """
              ALTER TABLE sqlitedata_icloud_metadata DROP COLUMN _deletionOrigin;
              DELETE FROM grdb_migrations WHERE identifier = 'Add Deletion Origin';
              """)
          }
        }
        do {
          let migrated = try DatabaseQueue(path: path)
          try migrate(metadatabase: migrated)
          try await migrated.read { db throws in
            #expect(try deletionOrigins(db) == ["legacy"])
            #expect(try SyncMetadata.select(\._isDeleted).fetchOne(db) == true)
          }
        }
        let reopened = try DatabaseQueue(path: path)
        try migrate(metadatabase: reopened)
        try await reopened.read { db throws in
          #expect(try deletionOrigins(db) == ["legacy"])
        }
      }
    }
  }

  private func deletionOrigins(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: """
      SELECT coalesce(_deletionOrigin, CASE WHEN _isDeleted THEN 'legacy' ELSE 'live' END)
      FROM sqlitedata_icloud_metadata ORDER BY recordPrimaryKey
      """)
  }
#endif
