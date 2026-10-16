#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dispatch
  import GRDB
  import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    /// Characterization tests: activity is not a database/delegate completion barrier.
    /// Every intermediate assertion is made while a SQL or delegate gate is closed, not
    /// after a sleep or a scheduler yield. Events still go through the real handler.
    @MainActor
    final class SyncEngineCompletionTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func finalApplyIsPendingAfterFetchingFlagClears() async throws {
        try await prepareRemoteUpdate(pending: true)
        let apply = CompletionSQLGate()
        try await installApplyGate(apply)
        defer { apply.open() }

        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        #expect(syncEngine.isFetchingChanges)
        let finished = LockIsolated(false)
        let task = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
          finished.setValue(true)
        }
        await apply.entered.wait()

        // The final retry is inside its transaction, but the public activity flag is idle.
        #expect(!syncEngine.isFetchingChanges)
        #expect(!syncEngine.isSynchronizing)
        #expect(!finished.value)

        apply.open()
        await task.value
        #expect(finished.value)
        try await expectTitle("Remote")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(CompletionReportingDelegate()))
      func terminalRollbackPrecedesReportButReportOutlivesFetchingFlag() async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        try await prepareRemoteUpdate(pending: true)
        let apply = CompletionSQLGate()
        try await installApplyGate(apply, fail: true)
        let writer = userDatabase.database
        delegate.query.setValue {
          // A writer query proves the failed apply transaction has released the writer.
          try await writer.write { db in
            try RemindersList.find(1).fetchOne(db)?.title
          }
        }
        defer {
          apply.open()
          delegate.release.signal()
        }

        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let finished = LockIsolated(false)
        let task = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
          finished.setValue(true)
        }
        await apply.entered.wait()
        #expect(!syncEngine.isFetchingChanges)
        #expect(delegate.errors.value.isEmpty)
        #expect(!finished.value)

        apply.open()
        await delegate.entered.wait()
        #expect(delegate.queryTitle.value == "Local")
        #expect(delegate.queryFailure.value == nil)
        #expect(delegate.errors.value.count == 1)
        #expect(delegate.errors.value.first?.context.operationKind == .fetchedRecordApplication)
        #expect(delegate.errors.value.first?.context.disposition == .terminalDroppedOrReconciled)
        let errorDescription = delegate.errors.value.first.map { String(describing: $0.error) }
        #expect(errorDescription?.contains("completion test rollback") == true)
        #expect(!syncEngine.isFetchingChanges)
        #expect(!finished.value)
        #expect(!delegate.finished.value)

        delegate.release.signal()
        await task.value
        #expect(delegate.finished.value)
        try await expectTitle("Local")
        // A terminal application error leaves the retry marker in the current API.
        try await expectPendingCount(1)
        try await userDatabase.write { db in
          try UnsyncedRecordID.all.delete().execute(db)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(CompletionReportingDelegate()))
      func cancellationReportCanSuspendOnWriterQuery() async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        try await prepareRemoteUpdate(pending: false)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        let query = CompletionSQLGate()
        let writer = userDatabase.database
        try await writer.write { db in
          db.add(function: DatabaseFunction("completion_query_gate", argumentCount: 0) { _ in
            query.block()
            return 0
          })
        }
        delegate.query.setValue {
          // Unstructured task intentionally escapes the cancelled event's cancellation.
          // The delegate must be able to inspect the durable retry state on the writer.
          try await Task {
            try await writer.write { db in
              try db.execute(sql: "SELECT completion_query_gate()")
              try #expect(UnsyncedRecordID.count().fetchOne(db) == 1)
              return try RemindersList.find(1).fetchOne(db)?.title
            }
          }.value
        }
        defer {
          query.open()
          delegate.release.signal()
        }

        let finished = LockIsolated(false)
        let task = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          await syncEngine.handleEvent(
            .fetchedRecordZoneChanges(modifications: [record], deletions: []),
            syncEngine: syncEngine.private
          )
          finished.setValue(true)
        }
        await query.entered.wait()
        #expect(delegate.errors.value.count == 1)
        #expect(delegate.errors.value.first?.error is CancellationError)
        #expect(delegate.errors.value.first?.context.operationKind == .fetchedRecordApplication)
        #expect(delegate.errors.value.first?.context.disposition == .transientPendingRetry)
        #expect(!syncEngine.isFetchingChanges)
        #expect(!finished.value)
        #expect(!delegate.finished.value)

        query.open()
        await delegate.entered.wait()
        #expect(delegate.queryTitle.value == "Local")
        #expect(delegate.queryFailure.value == nil)
        delegate.release.signal()
        await task.value
        #expect(delegate.finished.value)
        try await expectPendingCount(1)

        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        try await expectTitle("Remote")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func explicitFetchAwaitsApplyButDoesNotEstablishAStableEpoch() async throws {
        try await prepareRemoteUpdate(pending: false)
        let explicitApply = CompletionSQLGate()
        try await installApplyGate(explicitApply)
        defer { explicitApply.open() }
        let returned = LockIsolated(false)
        let fetch = Task {
          try await syncEngine.fetchChanges()
          returned.setValue(true)
        }
        await explicitApply.entered.wait()
        // Do not mischaracterize fetchChanges: it does await its explicit callbacks.
        #expect(!returned.value)
        explicitApply.open()
        try await fetch.value
        #expect(returned.value)
        try await expectTitle("Remote")

        let laterRecord = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        laterRecord.setValue("Later automatic fetch", forKey: "title", at: now + 2)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [laterRecord])
        try await userDatabase.write { db in
          try UnsyncedRecordID.insert {
            UnsyncedRecordID(recordID: RemindersList.recordID(for: 1))
          }.execute(db)
        }
        let automaticApply = CompletionSQLGate()
        try await installApplyGate(automaticApply)
        defer { automaticApply.open() }
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let automaticFinished = LockIsolated(false)
        let automatic = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
          automaticFinished.setValue(true)
        }
        await automaticApply.entered.wait()
        // A completed explicit fetch plus an idle flag is not a stable completion epoch:
        // a later automatic fetch can already have an uncommitted final apply in flight.
        #expect(returned.value)
        #expect(!syncEngine.isFetchingChanges)
        #expect(!automaticFinished.value)
        automaticApply.open()
        await automatic.value
        try await expectTitle("Later automatic fetch")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func prepareRemoteUpdate(pending: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Remote", forKey: "title", at: now + 1)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])
        if pending {
          try await userDatabase.write { db in
            try UnsyncedRecordID.insert {
              UnsyncedRecordID(recordID: RemindersList.recordID(for: 1))
            }.execute(db)
          }
        }
      }

      private func installApplyGate(_ gate: CompletionSQLGate, fail: Bool = false) async throws {
        try await userDatabase.database.write { db in
          db.add(function: DatabaseFunction("completion_apply_gate", argumentCount: 0) { _ in
            gate.block()
            return 0
          })
          try db.execute(sql: "DROP TRIGGER IF EXISTS completion_apply")
          // AFTER UPDATE makes the terminal case prove rollback, not just a rejected write.
          try db.execute(sql: """
            CREATE TRIGGER completion_apply AFTER UPDATE ON remindersLists
            BEGIN
              SELECT completion_apply_gate();
              \(fail ? "SELECT RAISE(ABORT, 'completion test rollback');" : "")
            END
            """)
        }
      }

      private func expectTitle(_ title: String) async throws {
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == title)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func expectPendingCount(_ count: Int) async throws {
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.count().fetchOne(db) == count)
        }
      }
    }
  }

  /// One-shot latch with synchronous signaling, usable from a SQLite callback.
  private final class CompletionLatch: Sendable {
    private struct State {
      var signaled = false
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())

    func wait() async {
      await withCheckedContinuation { continuation in
        let resume = state.withValue { state in
          if state.signaled { return true }
          state.waiters.append(continuation)
          return false
        }
        if resume { continuation.resume() }
      }
    }

    func signal() {
      let waiters = state.withValue { state in
        state.signaled = true
        defer { state.waiters.removeAll() }
        return state.waiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  /// Only blocks GRDB's writer queue, never the cooperative executor or main actor.
  /// Subsequent SQL invocations pass through once opened (upserts can update twice).
  private final class CompletionSQLGate: Sendable {
    let entered = CompletionLatch()
    private let semaphore = DispatchSemaphore(value: 0)
    private let opened = LockIsolated(false)

    func block() {
      entered.signal()
      if !opened.value { semaphore.wait() }
    }

    func open() {
      let wasOpened = opened.withValue { opened in
        defer { opened = true }
        return opened
      }
      if !wasOpened { semaphore.signal() }
    }
  }

  private final class CompletionReportingDelegate: SyncEngineDelegate {
    struct Report: Sendable {
      let error: any Error
      let context: SyncEngineErrorContext
    }
    let errors = LockIsolated<[Report]>([])
    let query = LockIsolated<(@Sendable () async throws -> String?)?>(nil)
    let queryTitle = LockIsolated<String?>(nil)
    let queryFailure = LockIsolated<String?>(nil)
    let entered = CompletionLatch()
    let release = CompletionLatch()
    let finished = LockIsolated(false)

    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {
      errors.withValue { $0.append(Report(error: error, context: context)) }
      do {
        if let query = query.value {
          let title = try await query()
          queryTitle.setValue(title)
        }
      } catch {
        queryFailure.setValue(String(describing: error))
      }
      entered.signal()
      await release.wait()
      finished.setValue(true)
    }
  }
#endif
