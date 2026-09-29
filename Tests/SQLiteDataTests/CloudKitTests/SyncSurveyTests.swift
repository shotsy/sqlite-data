#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation
  import GRDB
  import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    final class SyncSurveyTests: BaseCloudKitTests, @unchecked Sendable {
      let generation = LockIsolated(1)
      let events = LockIsolated<[SyncSurveyRunState]>([])
      let persisted = LockIsolated<[SyncSurveyCheckpoint]>([])

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func survey(
        _ previous: SyncSurveyCheckpoint?,
        maxPages: Int = 20,
        resultsLimit: Int = 200,
        duplicateCheck: (@Sendable (CKRecord, Database) throws -> SyncSurveyDuplicateCheck)? = nil,
        onRunState: @escaping @Sendable (SyncSurveyRunState) -> Void = { _ in }
      ) async throws -> SyncSurveyCheckpoint {
        try await syncEngine.surveyServerDiscrepancies(
          resuming: previous,
          options: SyncSurveyOptions(
            environment: "test",
            databaseGeneration: { [generation] in generation.value },
            maxPages: maxPages,
            resultsLimit: resultsLimit,
            duplicateCheck: duplicateCheck
          ),
          persist: { [persisted] checkpoint in persisted.withValue { $0.append(checkpoint) } },
          onRunState: { [events] state, _ in
            events.withValue { $0.append(state) }
            onRunState(state)
          }
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func seedSyncedLists(_ ids: ClosedRange<Int>) async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            for id in ids { RemindersList(id: id, title: "List \(id)") }
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func serverRecord(_ id: Int) throws -> CKRecord {
        try syncEngine.private.database.record(for: RemindersList.recordID(for: id))
      }

      /// Everything the survey must not touch: user rows, sync tables, and engine state.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func syncAndUserState() async throws -> [String] {
        let user = try await userDatabase.read { db in
          "\(try Row.fetchAll(db, sql: #"SELECT * FROM "remindersLists" ORDER BY "id""#))"
        }
        let sync = try await syncEngine.metadatabase.read { db in
          try [
            "metadata", "pendingRecordZoneChanges", "durableRecordZoneFailures",
            "unsyncedRecordIDs", "stateSerialization", "recordTypes",
          ]
          .map { "\(try Row.fetchAll(db, sql: #"SELECT * FROM "sqlitedata_icloud_\#($0)""#))" }
        }
        return [
          user, "\(sync)", "\(syncEngine.private.state.pendingRecordZoneChanges)",
          "\(syncEngine.private.state.pendingDatabaseChanges)",
        ]
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func counts(_ checkpoint: SyncSurveyCheckpoint) -> [String] {
        checkpoint.counts.map { "\($0.table) \($0.category)/\($0.reason) \($0.count)" }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func classifiesCandidatesInPrecedenceOrderWithoutWritingSyncOrUserData() async throws {
        try await seedSyncedLists(1...6)

        // 2: the device saw an edit, then missed a newer one (A-stale).
        let delivered = try serverRecord(2)
        delivered["_modificationDate"] = Date(timeIntervalSince1970: 1)
        try await syncEngine.modifyRecords(scope: .private, saving: [delivered]).notify()
        let stale = try serverRecord(2)
        stale["_modificationDate"] = Date(timeIntervalSince1970: 2)
        // 3: server tag changed but its date is not newer (A-other).
        let notNewer = try serverRecord(3)
        notNewer.setValue("Server 3", forKey: "title", at: now + 1)
        // 9, 10: on the server only (A-missing), one of which the app calls a duplicate.
        let missing = [9, 10].map { id in
          let record = CKRecord(
            recordType: RemindersList.tableName,
            recordID: RemindersList.recordID(for: id)
          )
          record.setValue(id == 9 ? "Dup" : "New", forKey: "title", at: now)
          return record
        }
        let unsupported = CKRecord(
          recordType: "unknownTable",
          recordID: CKRecord.ID(recordName: "1:unknownTable", zoneID: syncEngine.defaultZone.zoneID)
        )
        _ = try syncEngine.private.database.modifyRecords(
          saving: [stale, notNewer, unsupported] + missing,
          // 4: deleted on the server, still on the device (B-candidate).
          deleting: [RemindersList.recordID(for: 4)]
        )
        // 5: local edit not yet sent (protected).
        try await userDatabase.userWrite { db in
          try RemindersList.find(5).update { $0.title = "Local 5" }.execute(db)
        }
        // 6: terminal save failure (protected, and a C-candidate).
        try await syncEngine.metadatabase.write { db in
          try db.execute(
            sql: """
              INSERT INTO "sqlitedata_icloud_durableRecordZoneFailures"
              ("recordName", "zoneName", "ownerName", "action", "recordType", "errorCode",
               "attemptCount", "isTerminal")
              VALUES (?, ?, ?, 'save', 'remindersLists', 14, 1, 1)
              """,
            arguments: [
              RemindersList.recordID(for: 6).recordName,
              syncEngine.defaultZone.zoneID.zoneName,
              syncEngine.defaultZone.zoneID.ownerName,
            ]
          )
        }

        let before = try await syncAndUserState()
        let checkpoint = try await survey(nil) { record, _ in
          record.encryptedValues["title"] as? String == "Dup" ? .candidate : .notCandidate
        }
        #expect(try await syncAndUserState() == before)

        #expect(checkpoint.isComplete)
        #expect(events.value == [.started, .completed])
        #expect(
          counts(checkpoint) == [
            "remindersLists a_missing/duplicate_candidate 1",
            "remindersLists a_missing/no_duplicate 1",
            "remindersLists a_other/server_not_newer 1",
            "remindersLists a_stale/server_newer 1",
            "remindersLists b_candidate/not_seen_on_server 1",
            "remindersLists c_candidate/code14_row_baseline 1",
            "remindersLists protected/durable_failure 1",
            "remindersLists protected/pending_change 1",
            "remindersLists tag_current/row_present 1",
            "unknownTable protected/unsupported_record_type 1",
          ]
        )
        #expect(persisted.value.last == checkpoint)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func protectedAndOtherReasonsTakePrecedence() async throws {
        try await seedSyncedLists(1...5)
        let zoneID = syncEngine.defaultZone.zoneID
        try await syncEngine.metadatabase.write { db in
          // 1: tombstone wins over a durable failure.
          try db.execute(
            sql: #"UPDATE "sqlitedata_icloud_metadata" SET "_isDeleted" = 1 WHERE "recordName" = ?"#,
            arguments: [RemindersList.recordID(for: 1).recordName]
          )
          try db.execute(
            sql: """
              INSERT INTO "sqlitedata_icloud_durableRecordZoneFailures"
              ("recordName", "zoneName", "ownerName", "action", "recordType", "errorCode",
               "attemptCount", "isTerminal")
              VALUES (?, ?, ?, 'delete', 'remindersLists', 15, 1, 1)
              """,
            arguments: [RemindersList.recordID(for: 1).recordName, zoneID.zoneName, zoneID.ownerName]
          )
          // 2: unsynced record.
          try db.execute(
            sql: #"INSERT INTO "sqlitedata_icloud_unsyncedRecordIDs" VALUES (?, ?, ?)"#,
            arguments: [RemindersList.recordID(for: 2).recordName, zoneID.zoneName, zoneID.ownerName]
          )
          // 3: metadata without a baseline.
          try db.execute(
            sql: """
              UPDATE "sqlitedata_icloud_metadata" SET "_lastKnownServerRecordAllFields" = NULL
              WHERE "recordName" = ?
              """,
            arguments: [RemindersList.recordID(for: 3).recordName]
          )
          // 4: a row without metadata.
          try db.execute(
            sql: #"DELETE FROM "sqlitedata_icloud_metadata" WHERE "recordName" = ?"#,
            arguments: [RemindersList.recordID(for: 4).recordName]
          )
          // 8: metadata (copied from 5) without a row.
          try db.execute(
            sql: """
              INSERT INTO "sqlitedata_icloud_metadata"
              ("recordPrimaryKey", "recordType", "zoneName", "ownerName", "lastKnownServerRecord",
               "_lastKnownServerRecordAllFields", "userModificationTime")
              SELECT '8', "recordType", "zoneName", "ownerName", "lastKnownServerRecord",
              "_lastKnownServerRecordAllFields", "userModificationTime"
              FROM "sqlitedata_icloud_metadata" WHERE "recordName" = ?
              """,
            arguments: [RemindersList.recordID(for: 5).recordName]
          )
        }
        // 8, 9: on the server; 9 lacks the fields the duplicate check needs.
        let serverOnly = [8, 9].map { id in
          let record = CKRecord(
            recordType: RemindersList.tableName,
            recordID: RemindersList.recordID(for: id)
          )
          record.setValue("Server \(id)", forKey: "title", at: now)
          return record
        }
        _ = try syncEngine.private.database.modifyRecords(saving: serverOnly)

        let before = try await syncAndUserState()
        let checkpoint = try await survey(nil) { record, _ in
          record.recordID == RemindersList.recordID(for: 9) ? .missingFields : .notCandidate
        }
        #expect(try await syncAndUserState() == before)
        #expect(
          counts(checkpoint) == [
            "remindersLists a_other/metadata_without_row 1",
            "remindersLists a_other/row_without_metadata 1",
            "remindersLists protected/missing_baseline 1",
            "remindersLists protected/missing_projected_fields 1",
            "remindersLists protected/tombstone 1",
            "remindersLists protected/unsynced_record 1",
            "remindersLists tag_current/row_present 1",
          ]
        )

        try await syncEngine.metadatabase.write { db in
          try db.execute(sql: #"DELETE FROM "sqlitedata_icloud_unsyncedRecordIDs""#)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func resumesAfterInterruptionAndDropsServerDeletions() async throws {
        try await seedSyncedLists(1...3)

        let partial = try await survey(nil, maxPages: 1, resultsLimit: 1)
        #expect(!partial.isComplete)
        #expect(partial.pages == 1)
        #expect(counts(partial) == ["remindersLists tag_current/row_present 1"])

        // Deleted on the server after the first page, before the device hears about it.
        _ = try syncEngine.private.database.modifyRecords(
          deleting: [RemindersList.recordID(for: 1)]
        )
        let checkpoint = try await survey(partial, resultsLimit: 1)
        #expect(checkpoint.runID == partial.runID)
        #expect(checkpoint.isComplete)
        #expect(events.value == [.started, .resumed, .completed])
        #expect(
          counts(checkpoint) == [
            "remindersLists b_candidate/not_seen_on_server 1",
            "remindersLists tag_current/row_present 2",
          ]
        )

        // Once complete for this identity, it does nothing.
        #expect(try await survey(checkpoint) == checkpoint)
        #expect(events.value.count == 3)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cancellationStopsBeforeTheNextPage() async throws {
        try await seedSyncedLists(1...2)
        let task = Task {
          try await survey(nil, onRunState: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(persisted.value.map(\.pages) == [0])
        #expect(!events.value.contains(.completed))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func tokenExpiryRestartsUnderANewRun() async throws {
        try await seedSyncedLists(1...3)
        let partial = try await survey(nil, maxPages: 1, resultsLimit: 1)

        syncEngine.private.database.state.withValue { $0.expireNextZoneChangesToken = true }
        let checkpoint = try await survey(partial)
        #expect(checkpoint.runID != partial.runID)
        #expect(checkpoint.isComplete)
        #expect(checkpoint.pages == 1)
        #expect(events.value == [.started, .resumed, .started, .completed])
        #expect(counts(checkpoint) == ["remindersLists tag_current/row_present 3"])
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func identityChangeDiscardsProgressAndNeverCompletes() async throws {
        try await seedSyncedLists(1...2)
        let partial = try await survey(nil, maxPages: 1, resultsLimit: 1)

        // Database generation changes mid-run: the page is not checkpointed.
        await #expect(throws: SyncSurveyError.identityChanged) {
          try await self.survey(partial, onRunState: { [generation] _ in
            generation.withValue { $0 += 1 }
          })
        }
        #expect(persisted.value.map(\.pages) == [0, 1])
        #expect(!events.value.contains(.completed))

        // A new generation or iCloud user starts over.
        let regenerated = try await survey(partial, maxPages: 1, resultsLimit: 1)
        #expect(regenerated.runID != partial.runID)
        #expect(regenerated.identity.databaseGeneration == 2)
        container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "otherUser") }
        let otherUser = try await survey(regenerated)
        #expect(otherUser.runID != regenerated.runID)
        #expect(otherUser.identity.userRecordName == "otherUser")
        #expect(events.value == [.started, .resumed, .started, .started, .completed])
      }
    }
  }
#endif
