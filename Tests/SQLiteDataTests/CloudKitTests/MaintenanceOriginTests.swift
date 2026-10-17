#if canImport(CloudKit)
  import CloudKit
  import Foundation
  @testable import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    final class MaintenanceOriginTests: BaseCloudKitTests, @unchecked Sendable {
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
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .deleteRecord(RemindersList.recordID(for: 1)),
          .deleteRecord(RemindersList.recordID(for: 2)),
        ])
        // A fresh connection reads the durable origins, not connection-local state.
        let reopened = try DatabaseQueue(path: syncEngine.metadatabase.path)
        try await reopened.read { db throws in
          #expect(try deletionOrigins(db) == ["maintenance", "user"])
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.metadatabase.read { db throws in
          #expect(try SyncMetadata.count().fetchOne(db) == 0)
        }
        let cloud = container.privateCloudDatabase as! MockCloudDatabase
        #expect(throws: CKError.self) { try cloud.record(for: RemindersList.recordID(for: 1)) }
        #expect(throws: CKError.self) { try cloud.record(for: RemindersList.recordID(for: 2)) }
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
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlitedata_maintenanceContext") == 0)
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
