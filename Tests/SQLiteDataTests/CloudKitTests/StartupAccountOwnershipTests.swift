#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import Foundation
  @testable import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized)
    final class StartupAccountOwnershipTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func cachedSchemaRepairAcrossReset(reset: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setBytes(Array("old-account-image".utf8), forKey: "image", at: now + 1)
        try await syncEngine.modifyRecords(scope: .private, saving: [record]).notify()
        // The old schema cannot apply image, but caches the full server CKRecord.
        try await syncEngine.metadatabase.read { db in
          let cached = try #require(
            SyncMetadata.where { $0.recordType.eq(RemindersList.tableName) }
              .select(\._lastKnownServerRecordAllFields).fetchOne(db) ?? nil)
          #expect(cached["image"] is CKAsset)
        }
        syncEngine.stop()
        try await userDatabase.userWrite { db in
          try db.execute(sql: """
            ALTER TABLE remindersLists
            ADD COLUMN image BLOB NOT NULL ON CONFLICT REPLACE DEFAULT X''
            """)
        }

        let blocker = BlockingStartupDataManager(base: inMemoryDataManager)
        let engine = try await withDependencies {
          $0.dataManager = blocker
        } operation: {
          try await SyncEngine(
            container: container, userDatabase: userDatabase,
            tables: [SynchronizedTable(for: StartupListWithImage.self)],
            startImmediately: false)
        }
        defer {
          blocker.release.signal()
          engine.stop()
        }
        let startup = Task {
          try await withDependencies {
            $0.dataManager = blocker
          } operation: {
            try await engine.start()
          }
          blocker.finish()
        }
        // load() is called by real updateQuery, after the cached records were read and
        // the asset was downloaded, but before the schema-repair INSERT is submitted.
        for await _ in blocker.entered { break }
        try #require(blocker.didBlock)
        if reset {
          // Cancellation is cooperative, not an account-ownership guarantee. Keep the
          // real startup alive so GRDB cancellation cannot hide a missing writer fence.
          // The outer task still awaits it; only restart's cancellation handle is removed.
          engine.startTask.setValue(nil)
          try await engine.deleteLocalData()
          #expect(engine.isRunning)
          try await userDatabase.read { db in
            try #expect(StartupListWithImage.count().fetchOne(db) == 0)
          }
          try await engine.metadatabase.read { db in
            try #expect(SyncMetadata.count().fetchOne(db) == 0)
          }
          // Distinguish the replacement startup cache from the old startup's tail.
          try await userDatabase.write { db in
            try RecordType.where { $0.tableName.eq(RemindersList.tableName) }
              .update { $0.schema = "replacement-account-cache" }.execute(db)
          }
          try await engine.processPendingDatabaseChanges(scope: .private)
        } else {
          // Ordinary synchronous stop must NOT invalidate already-originated startup work.
          engine.stop()
        }
        blocker.release.signal()
        try await startup.value

        try await userDatabase.read { db in
          let rows = try StartupListWithImage.all.fetchAll(db)
          if reset {
            #expect(rows.isEmpty)
          } else {
            #expect(rows == [StartupListWithImage(
              id: 1, title: "Old account", image: Data("old-account-image".utf8))])
          }
        }
        if reset {
          try await engine.metadatabase.read { db in
            try #expect(SyncMetadata.count().fetchOne(db) == 0)
            try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
            try #expect(
              RecordType.where { $0.tableName.eq(RemindersList.tableName) }
                .select(\.schema).fetchOne(db) == "replacement-account-cache")
          }
          engine.private.state.assertPendingRecordZoneChanges([])
          engine.shared.state.assertPendingRecordZoneChanges([])
          engine.private.state.assertPendingDatabaseChanges([])
          // Reinstalled triggers must still enqueue actual new-account edits.
          try await userDatabase.userWrite { db in
            try db.seed { StartupListWithImage(id: 2, title: "New account", image: Data()) }
          }
          engine.private.state.assertPendingRecordZoneChanges([
            .saveRecord(StartupListWithImage.recordID(for: 2))
          ])
        }
      }
    }
  }

  @Table("remindersLists")
  private struct StartupListWithImage: Equatable {
    let id: Int
    var title: String
    var image: Data
  }

  // No production seam: pause the asset read used by actual startup query preparation.
  private final class BlockingStartupDataManager: DataManager, Sendable {
    let base: InMemoryDataManager
    let release = DispatchSemaphore(value: 0)
    let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let blocked = LockIsolated(false)

    init(base: InMemoryDataManager) {
      self.base = base
      (entered, continuation) = AsyncStream.makeStream()
    }

    var didBlock: Bool { blocked.value }
    func finish() { continuation.finish() }

    func load(_ url: URL) throws -> Data {
      let shouldBlock = blocked.withValue { blocked in
        guard !blocked else { return false }
        blocked = true
        return true
      }
      if shouldBlock {
        continuation.yield(())
        release.wait()
      }
      return try base.load(url)
    }
    func save(_ data: Data, to url: URL) throws { try base.save(data, to: url) }
    func sha256(of fileURL: URL) -> Data? { base.sha256(of: fileURL) }
    var temporaryDirectory: URL { base.temporaryDirectory }
  }
#endif
