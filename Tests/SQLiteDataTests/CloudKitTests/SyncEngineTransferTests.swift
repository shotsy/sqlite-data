#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import GRDB
  @testable import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized, $syncEngineDelegate.set(TransferDelegate()))
    final class SyncEngineTransferTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [CKDatabase.Scope.private, .shared])
      func committedFetchPreservesFullServerIdentity(scope: CKDatabase.Scope) async throws {
        let delegate = try recorder()
        let engine = syncEngine.syncEngine(for: scope)
        let record = listRecord(scope: scope)
        let version = try #require(SyncEngineRecordVersion(record))
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: engine)
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote")
        }
        #expect(delegate.outcomes.value.isEmpty)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .completed)
        #expect(outcome.direction == .download)
        #expect(outcome.context == delegate.context.value)
        #expect(outcome.databaseScope == scope)
        #expect(outcome.containerIdentifier == container.containerIdentifier)
        #expect(outcome.records == [version])
        #expect(
          outcome.records.first?.recordID.zoneID.ownerName == record.recordID.zoneID.ownerName)
        #expect(delegate.requestedScopes.value == [scope])
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func emptyTransfersDoNotInheritPriorEvidence() async throws {
        let delegate = try recorder()
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord()], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.count == 2)
        #expect(delegate.outcomes.value.map { $0.records.count } == [1, 0])
        #expect(delegate.outcomes.value.allSatisfy { $0.result == .completed })
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func missingChangeTagCannotConfirmFetch() async throws {
        let delegate = try recorder()
        let record = listRecord()
        record._recordChangeTag = nil
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .unconfirmed)
        #expect(outcome.records.isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unrelatedRecordIsNotCommittedUserData() async throws {
        let delegate = try recorder()
        let record = TransferRecord(
          recordType: "futureTable",
          recordID: CKRecord.ID(
            recordName: "1:futureTable", zoneID: SyncEngine.defaultTestZone.zoneID))
        record.setValue(1, forKey: "id", at: 10)
        record._recordChangeTag = 91
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .unconfirmed)
        #expect(outcome.records.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func localMergeIsExcludedFromServerVersionEvidence() async throws {
        let delegate = try recorder()
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Original") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let remote = listRecord()
        remote.setValue("Remote", forKey: "title", at: now + 1)
        remote._recordChangeTag = 99
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Local edit" }.execute(db)
        }
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [remote], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .unconfirmed)
        #expect(outcome.records.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Local edit")
        }
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func foreignKeyDeferredRecordIsNotEvidence() async throws {
        let delegate = try recorder()
        let record = TransferRecord(
          recordType: ChildWithOnDeleteSetNull.tableName,
          recordID: ChildWithOnDeleteSetNull.recordID(for: 1))
        record.setValue(1, forKey: "id", at: 10)
        record.setValue(999, forKey: "parentID", at: 10)
        // Retain a server copy so the final replay also sees the unresolved foreign key.
        let results = try syncEngine.private.database.modifyRecords(saving: [record])
        let saved = try #require(results.saveResults[record.recordID]).get()
        record._recordChangeTag = saved._recordChangeTag
        #expect(SyncEngineRecordVersion(record) != nil)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .unconfirmed)
        #expect(outcome.records.isEmpty)
        try await userDatabase.read { db in
          try #expect(ChildWithOnDeleteSetNull.count().fetchOne(db) == 0)
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == 1)
        }
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deferredRecordCanBecomeExactWhenParentArrivesInSameWindow() async throws {
        let delegate = try recorder()
        let child = TransferRecord(
          recordType: ChildWithOnDeleteSetNull.tableName,
          recordID: ChildWithOnDeleteSetNull.recordID(for: 1))
        child.setValue(1, forKey: "id", at: 10)
        child.setValue(999, forKey: "parentID", at: 10)
        child._recordChangeTag = 101
        let childVersion = try #require(SyncEngineRecordVersion(child))
        let parent = TransferRecord(
          recordType: Parent.tableName, recordID: Parent.recordID(for: 999))
        parent.setValue(999, forKey: "id", at: 10)
        parent._recordChangeTag = 102
        let parentVersion = try #require(SyncEngineRecordVersion(parent))
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [child], deletions: []),
          syncEngine: syncEngine.private)
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == 1)
        }
        #expect(delegate.outcomes.value.isEmpty)
        // A later event carries both records; topological application resolves the deferral.
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [child, parent], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .completed)
        #expect(outcome.records == [parentVersion, childVersion])
        try await userDatabase.read { db in
          try #expect(ChildWithOnDeleteSetNull.find(1).fetchOne(db)?.parentID == 999)
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedApplicationKeepsOnlyCommittedPartialEvidence() async throws {
        let delegate = try recorder()
        try await installFailureTrigger()
        let committed = listRecord(id: 1)
        let version = try #require(SyncEngineRecordVersion(committed))
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [committed, listRecord(id: 2)], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .failed)
        #expect(outcome.records == [version])
        #expect(delegate.events.value == ["error", "outcome"])
        #expect(delegate.errors.value.first?.operationKind == .fetchedRecordApplication)
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote")
          try #expect(RemindersList.find(2).fetchOne(db) == nil)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func finalReplayReadFailureCannotBecomeEmptySuccess() async throws {
        let delegate = try recorder()
        try await userDatabase.write { db in
          try UnsyncedRecordID.insert {
            UnsyncedRecordID(recordID: RemindersList.recordID(for: 1))
          }.execute(db)
        }
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        // No account-change event: this specifically exercises a throwing replay read.
        container._accountStatus.setValue(.temporarilyUnavailable)
        await withKnownIssue {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        } matching: {
          $0.description.contains("CKErrorDomain Code=36")
        }
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .failed)
        #expect(outcome.records.isEmpty)
        #expect(delegate.errors.value.first?.operationKind == .fetchedRecordApplication)
        #expect(delegate.events.value == ["error", "outcome"])
        container._accountStatus.setValue(.available)
        try await userDatabase.write { db in try UnsyncedRecordID.all.delete().execute(db) }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func accountChangeDuringSuspendedReportRetainsOriginalContext() async throws {
        let delegate = try recorder()
        let original = delegate.context.value
        let entered = TransferLatch()
        let release = TransferLatch()
        delegate.onError.setValue {
          entered.signal()
          await release.wait()
        }
        defer { release.signal() }
        try await installFailureTrigger()
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord()], deletions: []),
          syncEngine: syncEngine.private)
        let apply = Task {
          await syncEngine.handleEvent(
            .fetchedRecordZoneChanges(modifications: [listRecord(id: 2)], deletions: []),
            syncEngine: syncEngine.private)
        }
        await entered.wait()
        #expect(delegate.outcomes.value.isEmpty)
        delegate.context.setValue(Self.context())
        await syncEngine.handleEvent(
          .accountChange(
            changeType: .signOut(previousUser: CKRecord.ID(recordName: "old-account"))),
          syncEngine: syncEngine.private)
        release.signal()
        await apply.value
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.context == original)
        #expect(outcome.context != delegate.context.value)
        #expect(outcome.result == .interrupted)
        #expect(outcome.records.isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func scopesHaveIndependentCapturedContexts() async throws {
        let delegate = try recorder()
        let first = delegate.context.value
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let second = Self.context()
        delegate.context.setValue(second)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.shared)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord(scope: .shared)], deletions: []),
          syncEngine: syncEngine.shared)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.shared)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcomes = delegate.outcomes.value
        #expect(outcomes.count == 2)
        #expect(outcomes.map(\.context) == [second, first])
        #expect(outcomes.map(\.databaseScope) == [.shared, .private])
        #expect(outcomes.allSatisfy { $0.direction == .download })
        #expect(outcomes.map { $0.records.count } == [1, 0])
        #expect(outcomes.allSatisfy { $0.result == .completed })
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func overlappingAutomaticWindowsAreUnconfirmedAndFinishOnce() async throws {
        let delegate = try recorder()
        let first = delegate.context.value
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        delegate.context.setValue(Self.context())
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord()], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.isEmpty)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.count == 1)
        #expect(delegate.outcomes.value.first?.context == first)
        #expect(delegate.outcomes.value.first?.result == .unconfirmed)
        #expect(delegate.outcomes.value.first?.records.isEmpty == true)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func finalBoundaryRacingSuspendedApplicationCannotContaminateNewWindow() async throws {
        let delegate = try recorder()
        let original = delegate.context.value
        let entered = TransferLatch()
        let release = TransferLatch()
        delegate.onError.setValue {
          entered.signal()
          await release.wait()
        }
        defer { release.signal() }
        try await installFailureTrigger()
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let oldApplication = Task {
          // The third record is applied only after the old error callback resumes.
          await syncEngine.handleEvent(
            .fetchedRecordZoneChanges(
              modifications: [listRecord(id: 2), listRecord(id: 3)], deletions: []),
            syncEngine: syncEngine.private)
        }
        await entered.wait()
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.count == 1)
        #expect(delegate.outcomes.value.first?.context == original)
        #expect(delegate.outcomes.value.first?.result == .unconfirmed)
        #expect(delegate.outcomes.value.first?.records.isEmpty == true)

        delegate.context.setValue(Self.context())
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let currentRecord = listRecord(id: 4)
        let currentVersion = try #require(SyncEngineRecordVersion(currentRecord))
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [currentRecord], deletions: []),
          syncEngine: syncEngine.private)
        release.signal()
        await oldApplication.value
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.count == 2)
        let outcome = try #require(delegate.outcomes.value.last)
        #expect(outcome.context == delegate.context.value)
        #expect(outcome.result == .completed)
        #expect(outcome.records == [currentVersion])
        try await userDatabase.read { db in
          try #expect(RemindersList.find(3).fetchOne(db)?.title == "Remote")
          try #expect(RemindersList.find(4).fetchOne(db)?.title == "Remote")
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func committedValuesChangedByTriggerAreNotExactEvidence() async throws {
        let delegate = try recorder()
        try await userDatabase.write { db in
          try db.execute(
            sql: """
              CREATE TRIGGER transfer_rewrite AFTER INSERT ON remindersLists
              BEGIN
                UPDATE remindersLists SET title = 'REMOTE' WHERE id = NEW.id;
              END
              """)
        }
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord()], deletions: []),
          syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.result == .unconfirmed)
        #expect(outcome.records.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "REMOTE")
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func explicitFetchCapturesBothScopesBeforeFirstCallbackSuspends() async throws {
        let delegate = try recorder()
        let original = delegate.context.value
        let entered = TransferLatch()
        let release = TransferLatch()
        delegate.onOutcome.setValue { _ in
          entered.signal()
          await release.wait()
        }
        defer { release.signal() }
        let fetch = Task { try await syncEngine.fetchChanges() }
        await entered.wait()
        delegate.context.setValue(Self.context())
        release.signal()
        try await fetch.value
        let outcomes = delegate.outcomes.value
        #expect(outcomes.count == 2)
        #expect(Set(outcomes.map(\.databaseScope)) == Set([.private, .shared]))
        #expect(outcomes.allSatisfy { $0.context == original })
        #expect(outcomes.allSatisfy { $0.result == .completed && $0.records.isEmpty })
        #expect(Set(delegate.requestedScopes.value) == Set([.private, .shared]))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func retiredEngineDoesNotFinishReplacementWindow() async throws {
        let delegate = try recorder()
        let oldEngine = syncEngine.private
        let original = delegate.context.value
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: oldEngine)
        syncEngine.stop()
        delegate.context.setValue(Self.context())
        try await syncEngine.start()
        #expect(syncEngine.private !== oldEngine)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: oldEngine)
        #expect(delegate.outcomes.value.count == 1)
        #expect(delegate.outcomes.value.first?.result == .interrupted)
        #expect(delegate.outcomes.value.first?.context == original)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.count == 2)
        #expect(delegate.outcomes.value.last?.result == .completed)
        #expect(delegate.outcomes.value.last?.context == delegate.context.value)
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func outcomeCallbackIsAwaitedBeforeIdle() async throws {
        let delegate = try recorder()
        let entered = TransferLatch()
        let release = TransferLatch()
        let writer = userDatabase.database
        delegate.onOutcome.setValue { _ in
          // A writer query proves the callback runs outside the apply transaction.
          do {
            try await writer.write { db in
              try #expect(RemindersList.count().fetchOne(db) == 1)
            }
          } catch {
            Issue.record(error)
          }
          entered.signal()
          await release.wait()
        }
        defer { release.signal() }
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [listRecord()], deletions: []),
          syncEngine: syncEngine.private)
        let returned = LockIsolated(false)
        let finish = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
          returned.setValue(true)
        }
        await entered.wait()
        #expect(!returned.value)
        #expect(syncEngine.isFetchingChanges)
        #expect(delegate.outcomes.value.count == 1)
        release.signal()
        await finish.value
        #expect(returned.value)
        #expect(!syncEngine.isSynchronizing)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func nilContextIsUnconfirmedAndUnboundedEventsEmitNothing() async throws {
        let delegate = try recorder()
        delegate.context.setValue(nil)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(delegate.outcomes.value.isEmpty)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let outcome = try #require(delegate.outcomes.value.first)
        #expect(outcome.context == nil)
        #expect(outcome.result == .unconfirmed)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DefaultTransferDelegate()))
      func existingConformerUsesDefaultTransferMethods() async throws {
        let delegate = try #require(syncEngineDelegate as? DefaultTransferDelegate)
        #expect(delegate.syncEngine(syncEngine, transferContextFor: .private) == nil)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        #expect(!syncEngine.isSynchronizing)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [0, 1, 2, 3])
      func uploadRequiresAcknowledgedSaveAndRetainsPartialCoverage(mode: Int) async throws {
        let delegate = try recorder()
        let acknowledged = listRecord()
        let failed = listRecord(id: 2)
        let version = try #require(SyncEngineRecordVersion(acknowledged))
        let original = syncEngine.syncEngines.value
        let engine = TransferScriptEngine(base: syncEngine.private) { engine in
          #expect(!delegate.outcomes.value.contains { $0.databaseScope == .private })
          // Mode 0 prepares no acknowledged records; modes 1/2 acknowledge only record 1.
          await engine.base.parentSyncEngine.handleEvent(
            .sentRecordZoneChanges(
              savedRecords: mode == 1 || mode == 2 ? [acknowledged] : [],
              failedRecordSaves: mode >= 2 ? [(failed, CKError(.quotaExceeded))] : [],
              deletedRecordIDs: [], failedRecordDeletes: [:]), syncEngine: engine)
          #expect(!delegate.outcomes.value.contains { $0.databaseScope == .private })
        }
        syncEngine.syncEngines.setValue(SyncEngines(private: engine, shared: syncEngine.shared))
        defer { syncEngine.syncEngines.setValue(original) }
        try await syncEngine.sendChanges()
        let outcome = try #require(delegate.outcomes.value.first { $0.databaseScope == .private })
        #expect(outcome.direction == .upload)
        #expect(outcome.context == delegate.context.value)
        #expect(outcome.result == (mode == 0 ? .unconfirmed : mode == 1 ? .completed : .failed))
        #expect(outcome.records == (mode == 1 || mode == 2 ? [version] : []))
        if mode >= 2 { #expect(delegate.errors.value.count == 1) }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func thrownUploadAndMissingTagCannotEstablishSuccess() async throws {
        let delegate = try recorder()
        let original = syncEngine.syncEngines.value
        let record = listRecord()
        record._recordChangeTag = nil
        let engine = TransferScriptEngine(base: syncEngine.private) { engine in
          await engine.base.parentSyncEngine.handleEvent(
            .sentRecordZoneChanges(
              savedRecords: [record], failedRecordSaves: [],
              deletedRecordIDs: [], failedRecordDeletes: [:]), syncEngine: engine)
          throw CancellationError()
        }
        syncEngine.syncEngines.setValue(SyncEngines(private: engine, shared: syncEngine.shared))
        defer { syncEngine.syncEngines.setValue(original) }
        await #expect(throws: CancellationError.self) { try await syncEngine.sendChanges() }
        let outcome = try #require(delegate.outcomes.value.first { $0.databaseScope == .private })
        #expect(outcome.result == .interrupted)
        #expect(outcome.records.isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func recorder() throws -> TransferDelegate {
        let delegate = try #require(syncEngineDelegate as? TransferDelegate)
        delegate.reset(context: Self.context())
        return delegate
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      nonisolated private static func context() -> SyncEngineTransferContext {
        SyncEngineTransferContext(accountToken: UUID(), windowToken: UUID())
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func listRecord(id: Int = 1, scope: CKDatabase.Scope = .private) -> CKRecord {
        let zone =
          scope == .private
          ? SyncEngine.defaultTestZone.zoneID
          : CKRecordZone.ID(zoneName: "transfer.shared", ownerName: "another.owner")
        let record = TransferRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: id, zoneID: zone))
        record.setValue(id, forKey: "id", at: 10)
        record.setValue("Remote", forKey: "title", at: 10)
        record._recordChangeTag = 90 + id
        return record
      }

      private func installFailureTrigger() async throws {
        try await userDatabase.write { db in
          try db.execute(
            sql: """
              CREATE TRIGGER transfer_failure AFTER INSERT ON remindersLists
              WHEN NEW.id = 2
              BEGIN
                SELECT RAISE(ABORT, 'transfer application rollback');
              END
              """)
        }
      }
    }
  }

  // The repository mock's _recordChangeTag is a user field, not CKRecord's server tag.
  // Override the read-only server property for event fixtures without private SDK mutation.
  private final class TransferRecord: CKRecord, @unchecked Sendable {
    override var recordChangeTag: String? {
      _recordChangeTag.map { "server-version-\($0)" }
    }
  }

  private final class DefaultTransferDelegate: SyncEngineDelegate {}

  private final class TransferDelegate: SyncEngineDelegate {
    let context = LockIsolated<SyncEngineTransferContext?>(nil)
    let requestedScopes = LockIsolated<[CKDatabase.Scope]>([])
    let outcomes = LockIsolated<[SyncEngineTransferOutcome]>([])
    let errors = LockIsolated<[SyncEngineErrorContext]>([])
    let events = LockIsolated<[String]>([])
    let onError = LockIsolated<(@Sendable () async -> Void)?>(nil)
    let onOutcome = LockIsolated<(@Sendable (SyncEngineTransferOutcome) async -> Void)?>(nil)

    func reset(context: SyncEngineTransferContext) {
      self.context.setValue(context)
      requestedScopes.setValue([])
      outcomes.setValue([])
      errors.setValue([])
      events.setValue([])
      onError.setValue(nil)
      onOutcome.setValue(nil)
    }

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine, transferContextFor databaseScope: CKDatabase.Scope
    ) -> SyncEngineTransferContext? {
      requestedScopes.withValue { $0.append(databaseScope) }
      return context.value
    }

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine, didFinishTransfer outcome: SyncEngineTransferOutcome
    ) async {
      outcomes.withValue { $0.append(outcome) }
      events.withValue { $0.append("outcome") }
      await onOutcome.value?(outcome)
    }

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine, didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {
      errors.withValue { $0.append(context) }
      events.withValue { $0.append("error") }
      await onError.value?()
    }

    // Keep the test's rows intact; production account handling still invalidates transfers.
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {}
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class TransferScriptEngine: SyncEngineProtocol {
    let base: MockSyncEngine
    let send: @Sendable (TransferScriptEngine) async throws -> Void
    var database: MockCloudDatabase { base.database }
    var state: MockSyncEngineState { base.state }
    init(
      base: MockSyncEngine, send: @escaping @Sendable (TransferScriptEngine) async throws -> Void
    ) {
      self.base = base
      self.send = send
    }
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
      try await send(self)
    }
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {}
    func cancelOperations() async {}
    func recordZoneChangeBatch(
      pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
      recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await base.recordZoneChangeBatch(
        pendingChanges: pendingChanges, recordProvider: recordProvider)
    }
  }

  private final class TransferLatch: Sendable {
    private struct State {
      var signaled = false
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())

    func wait() async {
      await withCheckedContinuation { continuation in
        let resume = state.withValue {
          if $0.signaled { return true }
          $0.waiters.append(continuation)
          return false
        }
        if resume { continuation.resume() }
      }
    }

    func signal() {
      let waiters = state.withValue { value in
        value.signaled = true
        defer { value.waiters.removeAll() }
        return value.waiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }
#endif
