#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import GRDB
  @testable import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    final class SyncAttemptReceiptTests: BaseCloudKitTests, @unchecked Sendable {
      @Test(arguments: [false, true])
      func successAndFreshEpoch(send: Bool) async throws {
        try await scripted { _, _ in
        } operation: {
          let first = try await receipt(send)
          #expect(first.result == .succeeded)
          #expect(first.failures.isEmpty)
          #expect(syncEngine.isValid(first.settlementToken))
          let second = try await receipt(send)
          #expect(second.result == .succeeded)
          #expect(second.attemptID != first.attemptID)
          #expect(!syncEngine.isValid(first.settlementToken))
          try syncEngine.withSettlementLease(second.settlementToken) {}
        }
      }

      @Test(arguments: [false, true], [CKDatabase.Scope.private, .shared])
      func thrownTransportFailure(send: Bool, scope: CKDatabase.Scope) async throws {
        let error = NSError(domain: "receipt-test", code: 42)
        try await scripted { engine, _ in
          if engine.database.databaseScope == scope { throw error }
        } operation: {
          let result = try await receipt(send)
          #expect(result.result == .failed)
          let failure = try #require(result.failures.first)
          #expect(failure.attemptID == result.attemptID)
          #expect(failure.error as NSError === error)
          #expect(failure.context.databaseScope == scope)
          #expect(failure.context.operation == (send ? "sendChanges" : "fetchChanges"))
          #expect(failure.context.operationKind == (send ? nil : .fetchChanges))
        }
      }

      @Test(arguments: [CKError.Code.networkFailure, .partialFailure, .zoneNotFound])
      func zoneFetchErrorsAndDeduplicatedThrow(code: CKError.Code) async throws {
        let error = CKError(code, userInfo: [CKErrorRetryAfterKey: 12])
        let zone = CKRecordZone.ID(zoneName: "failed")
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          await engine.emit(.didFetchRecordZoneChanges(zoneID: zone, error: error))
          throw error
        } operation: {
          let result = try await receipt(false)
          #expect(result.result == .failed)
          #expect(result.failures.count == 1)
          let failure = try #require(result.failures.first)
          #expect((failure.error as NSError).isEqual(error as NSError))
          #expect(failure.context.zoneID == zone)
          #expect(failure.context.operationKind == .fetchRecordZoneChanges)
        }
      }

      @Test(arguments: [false, true])
      func databaseSendErrors(deleting: Bool) async throws {
        let zone = CKRecordZone(zoneName: "failed-send")
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .shared else { return }
          await engine.emit(
            .sentDatabaseChanges(
              savedZones: [], failedZoneSaves: deleting ? [] : [(zone, CKError(.zoneBusy))],
              deletedZoneIDs: [],
              failedZoneDeletes: deleting ? [zone.zoneID: CKError(.zoneBusy)] : [:]
            ))
        } operation: {
          let result = try await receipt(true)
          #expect(result.result == .failed)
          #expect(result.failures.count == 1)
          #expect(result.failures.first?.context.operation == "sentDatabaseChanges")
          #expect(result.failures.first?.context.operationKind == nil)
          #expect(result.failures.first?.context.databaseScope == .shared)
          #expect(result.failures.first?.context.zoneID == zone.zoneID)
        }
      }

      @Test(
        arguments: [false, true],
        [CKError.Code.networkFailure, .zoneNotFound, .serverRecordChanged])
      func recordSendErrors(deleting: Bool, code: CKError.Code) async throws {
        let record = CKRecord(
          recordType: "remindersLists", recordID: RemindersList.recordID(for: 1))
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          await engine.emit(
            .sentRecordZoneChanges(
              savedRecords: [], failedRecordSaves: deleting ? [] : [(record, CKError(code))],
              deletedRecordIDs: [],
              failedRecordDeletes: deleting ? [record.recordID: CKError(code)] : [:]
            ))
        } operation: {
          let result = try await receipt(true)
          #expect(result.result == .failed)
          #expect(result.failures.count == 1)
          #expect(
            result.failures.first?.context.operationKind
              == (deleting ? .sentRecordDelete : .sentRecordSave))
          #expect(result.failures.first?.attemptID == result.attemptID)
        }
        syncEngine.private.state.removePendingChanges()
      }

      @Test(arguments: ["application", "deletion", "zone"])
      func fetchedApplicationErrors(kind: String) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Remote", forKey: "title", at: now + 1)
        try await userDatabase.write { db in
          try db.execute(
            sql: """
              CREATE TRIGGER receipt_failure BEFORE \(kind == "application" ? "UPDATE" : "DELETE")
              ON remindersLists BEGIN SELECT RAISE(ABORT, 'receipt application failure'); END
              """)
        }
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          switch kind {
          case "application":
            await engine.emit(.fetchedRecordZoneChanges(modifications: [record], deletions: []))
          case "deletion":
            await engine.emit(
              .fetchedRecordZoneChanges(
                modifications: [], deletions: [(record.recordID, record.recordType)]))
          default:
            await engine.emit(
              .fetchedDatabaseChanges(
                modifications: [], deletions: [(record.recordID.zoneID, .deleted)]))
          }
        } operation: {
          let check = {
            let result = try await self.receipt(false)
            #expect(result.result == .failed)
            #expect(result.failures.count == 1)
            #expect(result.failures.first?.attemptID == result.attemptID)
            let operation: SyncEngineOperation =
              kind == "application"
              ? .fetchedRecordApplication
              : kind == "deletion" ? .fetchedRecordDeletion : .zoneDeletion
            #expect(result.failures.first?.context.operationKind == operation)
          }
          if kind == "application" {
            try await check()
          } else {
            try await withKnownIssue {
              try await check()
            } matching: {
              $0.description.contains("receipt application failure")
            }
          }
        }
        syncEngine.private.state.removePendingChanges()
      }

      @Test(arguments: [false, true])
      func outgoingAssetStagingFailureKeepsSaveRetryable(previouslyUploaded: Bool) async throws {
        let recordID = RemindersListAsset.recordID(for: 1)
        let originalBytes = Data([1, 2, 3])
        let editedBytes = Data([4, 5, 6])
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Parent") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersListAsset(remindersListID: 1, coverImage: originalBytes)
          }
        }
        if previouslyUploaded {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
          try await userDatabase.userWrite { db in
            try RemindersListAsset.find(1).update { $0.coverImage = #bind(editedBytes) }.execute(db)
          }
        }
        let baseline = try await syncEngine.metadatabase.read { db -> [Data?] in
          let row = try #require(
            try Row.fetchOne(
              db,
              sql: """
                SELECT lastKnownServerRecord, _lastKnownServerRecordAllFields
                FROM sqlitedata_icloud_metadata WHERE recordType = ?
                """,
              arguments: [RemindersListAsset.tableName]))
          return [row[0], row[1]]
        }
        let error = NSError(domain: "receipt-asset-staging", code: 28)
        let failingDataManager = ReceiptFailingDataManager(base: inMemoryDataManager, error: error)
        let uploadedCount = LockIsolated(0)
        try await scripted { engine, send in
          #expect(send)
          guard engine.database.databaseScope == .private else { return }
          let batch = try #require(
            await engine.base.parentSyncEngine.nextRecordZoneChangeBatch(syncEngine: engine))
          uploadedCount.withValue { $0 += batch.recordsToSave.count }
          let results = try engine.database.modifyRecords(saving: batch.recordsToSave)
          let savedRecords = try results.saveResults.values.map { try $0.get() }
          await engine.emit(
            .sentRecordZoneChanges(
              savedRecords: savedRecords, failedRecordSaves: [], deletedRecordIDs: [],
              failedRecordDeletes: [:]))
        } operation: {
          let result = try await withDependencies {
            $0.dataManager = failingDataManager
          } operation: {
            try await receipt(true)
          }
          #expect(result.result == .failed)
          #expect(result.failures.count == 1)
          let failure = try #require(result.failures.first)
          #expect(failure.attemptID == result.attemptID)
          #expect(failure.error as NSError === error)
          #expect(failure.context.operation == "sendChanges")
          #expect(failure.context.operationKind == nil)
          #expect(failure.context.databaseScope == .private)
          #expect(failure.context.zoneID == recordID.zoneID)
          #expect(failure.context.recordType == RemindersListAsset.tableName)
          #expect(failure.context.isLocalSaveFailure)
        }
        #expect(failingDataManager.saveAttempts.value == 1)
        #expect(uploadedCount.value == 0)
        #expect(syncEngine.private.state.pendingRecordZoneChanges == [.saveRecord(recordID)])
        let afterFailure = try await syncEngine.metadatabase.read { db -> [Data?] in
          let row = try #require(
            try Row.fetchOne(
              db,
              sql: """
                SELECT lastKnownServerRecord, _lastKnownServerRecordAllFields
                FROM sqlitedata_icloud_metadata WHERE recordType = ?
                """,
              arguments: [RemindersListAsset.tableName]))
          return [row[0], row[1]]
        }
        #expect(afterFailure == baseline)
        // A healthy retry must stage and upload the edited bytes, not the stale asset.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let uploaded = try syncEngine.private.database.record(for: recordID)
        let asset = try #require(uploaded["coverImage"] as? CKAsset)
        let url = try #require(asset.fileURL)
        #expect(try dataManager.load(url) == (previouslyUploaded ? editedBytes : originalBytes))
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      @Test
      func assetReadFailureKeepsEpochThroughWriter() async throws {
        let parent = CKRecord(
          recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
        parent.setValue(1, forKey: "id", at: now)
        parent.setValue("Parent", forKey: "title", at: now)
        let record = CKRecord(
          recordType: RemindersListAsset.tableName, recordID: RemindersListAsset.recordID(for: 1))
        record.setValue(1, forKey: "remindersListID", at: now)
        record.setAsset(
          CKAsset(fileURL: URL(fileURLWithPath: "/missing-receipt-asset")), forKey: "coverImage",
          at: now)
        try await scripted { engine, _ in
          if engine.database.databaseScope == .private {
            await engine.emit(
              .fetchedRecordZoneChanges(modifications: [parent, record], deletions: []))
          }
        } operation: {
          let result = try await receipt(false)
          #expect(result.result == .failed)
          #expect(result.failures.count >= 1)
          #expect(result.failures.allSatisfy { $0.attemptID == result.attemptID })
        }
      }

      @Test
      func foreignKeyDeferralIsFailure() async throws {
        let record = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
        record.setValue(1, forKey: "id", at: now)
        record.setValue("Orphan", forKey: "title", at: now)
        record.setValue(999, forKey: "remindersListID", at: now)
        try await scripted { engine, _ in
          if engine.database.databaseScope == .private {
            await engine.emit(.fetchedRecordZoneChanges(modifications: [record], deletions: []))
          }
        } operation: {
          let result = try await receipt(false)
          #expect(result.result == .failed)
          #expect(result.failures.contains { $0.context.disposition == .transientPendingRetry })
          #expect(result.failures.allSatisfy { $0.attemptID == result.attemptID })
        }
      }

      @Test
      func sendPersistenceFailure() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        try await syncEngine.metadatabase.write { db in
          try db.execute(
            sql: """
              CREATE TRIGGER receipt_metadata_failure BEFORE UPDATE ON sqlitedata_icloud_metadata
              BEGIN SELECT RAISE(ABORT, 'receipt metadata failure'); END
              """)
        }
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          await engine.emit(
            .sentRecordZoneChanges(
              savedRecords: [record], failedRecordSaves: [], deletedRecordIDs: [],
              failedRecordDeletes: [:]))
        } operation: {
          try await withKnownIssue {
            let result = try await receipt(true)
            #expect(result.result == .failed)
            #expect(result.failures.count == 1)
            #expect(
              String(describing: result.failures[0].error).contains("receipt metadata failure"))
          } matching: {
            $0.description.contains("receipt metadata failure")
          }
        }
      }

      @Test($syncEngineDelegate.set(ReceiptSuspendedDelegate()))
      func awaitedOriginalReportAndOverlap() async throws {
        let delegate = try #require(syncEngineDelegate as? ReceiptSuspendedDelegate)
        let eventTask = LockIsolated<Task<Void, Never>?>(nil)
        let calls = LockIsolated(0)
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          let call = calls.withValue {
            $0 += 1
            return $0
          }
          if call == 1 {
            eventTask.setValue(
              Task {
                await engine.emit(
                  .didFetchRecordZoneChanges(
                    zoneID: CKRecordZone.ID(zoneName: "late"), error: CKError(.networkFailure)))
              })
            await delegate.entered.wait()
            throw CKError(.networkFailure)
          }
        } operation: {
          let done = LockIsolated(false)
          let first = Task {
            let result = try await receipt(false)
            done.setValue(true)
            return result
          }
          await delegate.entered.wait()
          #expect(!done.value)
          let secondStarted = ReceiptLatch()
          let second = Task {
            secondStarted.signal()
            return try await receipt(false)
          }
          await secondStarted.wait()
          // Wait until the second explicit private operation actually runs, without timing sleeps.
          while calls.value < 2 { await Task.yield() }
          #expect(!done.value)
          delegate.release.signal()
          let old = try await first.value
          let new = try await second.value
          #expect(old.result == .failed)
          #expect(old.failures.count == 1)
          #expect(new.result == .unconfirmed)
          #expect(new.failures.isEmpty)
          await eventTask.value?.value
          let clean = try await receipt(false)
          #expect(clean.result == .succeeded)
          #expect(clean.failures.isEmpty)
        }
      }

      @Test(arguments: [false, true])
      func cancellationNeverSucceeds(send: Bool) async throws {
        try await scripted { engine, _ in
          if engine.database.databaseScope == .private { throw CancellationError() }
        } operation: {
          await #expect(throws: CancellationError.self) { try await receipt(send) }
        }
      }

      @Test($syncEngineDelegate.set(ErrorReportingDelegate()))
      func accountChangeWithoutRestartNeverSucceeds() async throws {
        await scripted { engine, _ in
          if engine.database.databaseScope == .private {
            await engine.emit(
              .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))))
          }
        } operation: {
          await #expect(throws: CancellationError.self) { try await receipt(false) }
        }
      }

      @Test($syncEngineDelegate.set(ReceiptFailureDelegate()))
      func automaticFailuresKeepEpochAcrossSuspendedReport() async throws {
        let delegate = try #require(syncEngineDelegate as? ReceiptFailureDelegate)
        let engine = syncEngine.private
        let zone = CKRecordZone.ID(zoneName: "automatic")
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        let oldEvent = Task {
          await syncEngine.handleEvent(
            .didFetchRecordZoneChanges(zoneID: zone, error: CKError(.networkFailure)),
            syncEngine: engine)
        }
        await delegate.entered.wait()
        let oldID = try #require(delegate.failures.value.first?.attemptID)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zone, error: CKError(.zoneBusy)), syncEngine: engine)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        let newID = try #require(delegate.failures.value.last?.attemptID)
        #expect(newID != oldID)
        let done = LockIsolated(false)
        let admitted = ReceiptLatch()
        let receiptTask = Task {
          try await scripted { engine, _ in
            if engine.database.databaseScope == .private { admitted.signal() }
          } operation: {
            let result = try await receipt(false)
            #expect(result.result == .unconfirmed)
            #expect(result.failures.isEmpty)
            done.setValue(true)
          }
        }
        // The failure delegate itself remains admitted work until it returns.
        await admitted.wait()
        #expect(!done.value)
        delegate.release.signal()
        await oldEvent.value
        try await receiptTask.value
        #expect(delegate.failures.value.first?.attemptID == oldID)
      }

      @Test($syncEngineDelegate.set(ReceiptFailureDelegate(blockFirst: false)))
      func automaticSendFailureUsesStableEpoch() async throws {
        let delegate = try #require(syncEngineDelegate as? ReceiptFailureDelegate)
        let zone = CKRecordZone(zoneName: "automatic-send")
        for _ in 0..<2 {
          await syncEngine.handleEvent(
            .sentDatabaseChanges(
              savedZones: [], failedZoneSaves: [(zone, CKError(.zoneBusy))],
              deletedZoneIDs: [], failedZoneDeletes: [:]), syncEngine: syncEngine.private)
        }
        #expect(delegate.failures.value.count == 2)
        #expect(delegate.failures.value[0].attemptID == delegate.failures.value[1].attemptID)
        #expect(
          delegate.failures.value.allSatisfy { $0.context.operation == "sentDatabaseChanges" })
      }

      @Test($syncEngineDelegate.set(ReceiptFailureDelegate()))
      func drainWaitsForExplicitFailureDelivery() async throws {
        let send = true
        let delegate = try #require(syncEngineDelegate as? ReceiptFailureDelegate)
        try await scripted { engine, _ in
          if engine.database.databaseScope == .private { throw CKError(.networkFailure) }
        } operation: {
          let attempt = Task { try await receipt(send) }
          await delegate.entered.wait()
          let drained = LockIsolated(false)
          let drain = Task {
            try await syncEngine.stopAndDrain()
            drained.setValue(true)
          }
          while syncEngine.isRunning { await Task.yield() }
          #expect(!drained.value)
          await #expect(throws: CancellationError.self) { try await receipt(send) }
          delegate.release.signal()
          await #expect(throws: CancellationError.self) { try await attempt.value }
          try await drain.value
          #expect(drained.value)
          #expect(delegate.failures.value.count == 1)
        }
        syncEngine.stop()
      }

      @Test($syncEngineDelegate.set(ReceiptFailureDelegate()))
      func drainWaitsForDirectFailureDelivery() async throws {
        let delegate = try #require(syncEngineDelegate as? ReceiptFailureDelegate)
        let engine = syncEngine.private
        let recordID = RemindersList.recordID(for: 999)
        let callback = Task {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordDeletes: [recordID: CKError(.unknownItem)], syncEngine: engine)
        }
        await delegate.entered.wait()
        let drained = LockIsolated(false)
        let drain = Task {
          try await syncEngine.stopAndDrain()
          drained.setValue(true)
        }
        while syncEngine.isRunning { await Task.yield() }
        #expect(!drained.value)
        delegate.release.signal()
        await callback.value
        try await drain.value
        #expect(drained.value)
        #expect(delegate.failures.value.count == 1)
      }

      @Test
      func lateProviderCannotMutateRetiredQueue() async throws {
        let entered = ReceiptLatch()
        let release = ReceiptLatch()
        let recordID = RemindersList.recordID(for: 999)
        try await scripted({ _, _ in }, beforeProvider: {
          entered.signal()
          await release.wait()
        }) {
          let engine = syncEngine.syncEngines.withValue { $0.private! }
          engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
          let batch = Task { await syncEngine.nextRecordZoneChangeBatch(syncEngine: engine) }
          await entered.wait()
          let drained = LockIsolated(false)
          let drain = Task {
            try await syncEngine.stopAndDrain()
            drained.setValue(true)
          }
          while syncEngine.isRunning { await Task.yield() }
          #expect(!drained.value)
          release.signal()
          #expect(await batch.value?.recordsToSave.isEmpty == true)
          try await drain.value
          // Retirement transfers the queue into the journal; the late provider must not
          // consume the missing record's preserved upload intent.
          let pending = try? await syncEngine.metadatabase.read { db in
            try PendingRecordZoneChange.select(\.pendingRecordZoneChange).fetchAll(db)
          }
          #expect(pending?.contains(.saveRecord(recordID)) == true)
        }
        syncEngine.stop()
      }

      @Test($syncEngineDelegate.set(ReceiptFailureDelegate(blockFirst: false)))
      func compositeKeepsOriginAndDeliversFailure() async throws {
        let delegate = try #require(syncEngineDelegate as? ReceiptFailureDelegate)
        let fetches = LockIsolated(0)
        try await scripted { engine, sending in
          if sending && engine.database.databaseScope == .private {
            throw CKError(.networkFailure)
          }
          if !sending { fetches.withValue { $0 += 1 } }
        } operation: {
          await #expect(throws: CKError.self) { try await syncEngine.syncChanges() }
          #expect(fetches.value == 0)
          #expect(delegate.failures.value.count == 1)
          #expect(delegate.failures.value.first?.context.operation == "sendChanges")
          #expect(delegate.failures.value.first?.context.operationKind == nil)
        }
      }

      // Receipt-only behavior was unconfirmed; drain admission now rejects the retired
      // callback entirely, so neither a successful nor failing retired event contaminates it.
      @Test(arguments: [false, true])
      func retiredCallbackDuringNewAttemptIsRejected(failing: Bool) async throws {
        let retired = syncEngine.private
        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await scripted { engine, _ in
          guard engine.database.databaseScope == .private else { return }
          await engine.base.parentSyncEngine.handleEvent(
            .didFetchRecordZoneChanges(
              zoneID: CKRecordZone.ID(zoneName: "retired"),
              error: failing ? CKError(.networkFailure) : nil),
            syncEngine: retired)
        } operation: {
          let result = try await receipt(false)
          #expect(result.result == .succeeded)
          #expect(result.failures.isEmpty)
        }
      }

      @Test
      func compositeCannotFetchReplacementEngines() async throws {
        let fetched = LockIsolated(false)
        try await scripted { engine, sending in
          if sending && engine.database.databaseScope == .private {
            engine.base.parentSyncEngine.stop()
            try await engine.base.parentSyncEngine.start()
          }
          if !sending { fetched.setValue(true) }
        } operation: {
          await #expect(throws: CancellationError.self) { try await syncEngine.syncChanges() }
          #expect(!fetched.value)
        }
        syncEngine.stop()
      }

      private func receipt(_ send: Bool) async throws -> SyncEngine.AttemptReceipt {
        if send { return try await syncEngine.sendChangesWithReceipt() }
        return try await syncEngine.fetchChangesWithReceipt()
      }

      private func scripted(
        _ action: @escaping ReceiptEngine.Action,
        beforeProvider: @escaping @Sendable () async -> Void = {},
        operation: () async throws -> Void
      ) async rethrows {
        let original = syncEngine.syncEngines.withValue { engines in
          let original = engines
          engines = SyncEngines(
            private: ReceiptEngine(
              base: engines.private as! MockSyncEngine, action: action, beforeProvider: beforeProvider),
            shared: ReceiptEngine(
              base: engines.shared as! MockSyncEngine, action: action, beforeProvider: beforeProvider))
          return original
        }
        defer { syncEngine.syncEngines.withValue { engines in engines = original } }
        try await operation()
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class ReceiptEngine: SyncEngineProtocol {
    typealias Action = @Sendable (ReceiptEngine, Bool) async throws -> Void
    let base: MockSyncEngine
    let action: Action
    let beforeProvider: @Sendable () async -> Void
    var database: MockCloudDatabase { base.database }
    var state: MockSyncEngineState { base.state }
    init(
      base: MockSyncEngine, action: @escaping Action,
      beforeProvider: @escaping @Sendable () async -> Void
    ) {
      self.base = base
      self.action = action
      self.beforeProvider = beforeProvider
    }
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
      try await action(self, false)
    }
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
      try await action(self, true)
    }
    func cancelOperations() async {}
    func emit(_ event: SyncEngine.Event) async {
      await base.parentSyncEngine.handleEvent(event, syncEngine: self)
    }
    func recordZoneChangeBatch(
      pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
      recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await beforeProvider()
      return await base.recordZoneChangeBatch(
        pendingChanges: pendingChanges, recordProvider: recordProvider)
    }
  }

  private struct ReceiptFailingDataManager: DataManager {
    let base: InMemoryDataManager
    let error: NSError
    let saveAttempts = LockIsolated(0)
    var temporaryDirectory: URL { base.temporaryDirectory }
    func load(_ url: URL) throws -> Data { try base.load(url) }
    func sha256(of fileURL: URL) -> Data? { base.sha256(of: fileURL) }
    func save(_ data: Data, to url: URL) throws {
      saveAttempts.withValue { $0 += 1 }
      throw error
    }
  }

  private final class ReceiptLatch: Sendable {
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

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class ReceiptFailureDelegate: SyncEngineDelegate {
    let failures = LockIsolated<[SyncEngine.AttemptReceipt.Failure]>([])
    let entered = ReceiptLatch()
    let release = ReceiptLatch()
    let blockFirst: Bool
    init(blockFirst: Bool = true) { self.blockFirst = blockFirst }
    func syncEngine(
      _ syncEngine: SyncEngine, didReportFailure failure: SyncEngine.AttemptReceipt.Failure
    ) async {
      let count = failures.withValue {
        $0.append(failure)
        return $0.count
      }
      if count == 1 && blockFirst {
        entered.signal()
        await release.wait()
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class ReceiptSuspendedDelegate: SyncEngineDelegate {
    let entered = ReceiptLatch()
    let release = ReceiptLatch()
    func syncEngine(
      _ syncEngine: SyncEngine, didReportError error: any Error, context: SyncEngineErrorContext
    ) async {
      entered.signal()
      await release.wait()
    }
  }
#endif
