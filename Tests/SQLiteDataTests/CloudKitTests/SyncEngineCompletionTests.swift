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
    /// SQL/delegate gates establish pending work. A serial-executor yield registers
    /// settlement waiters; no sleeps are used. Events go through the real handler.
    @MainActor
    @Suite(.serialized)
    final class SyncEngineCompletionTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [CKDatabase.Scope.private, .shared])
      func finalApplyKeepsFetchingActiveUntilCommit(scope: CKDatabase.Scope) async throws {
        try await prepareRemoteUpdate(pending: true, scope: scope)
        let engine = syncEngine.syncEngine(for: scope)
        let previous = try await syncEngine.waitForSettlement()
        let apply = CompletionSQLGate()
        try await installApplyGate(apply)
        defer { apply.open() }

        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        #expect(syncEngine.isFetchingChanges)
        #expect(!syncEngine.isValid(previous))
        let finished = LockIsolated(false)
        let task = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
          finished.setValue(true)
        }
        await apply.entered.wait()

        // The final retry now owns the activity edge until application and reporting finish.
        #expect(syncEngine.isFetchingChanges)
        #expect(syncEngine.isSynchronizing)
        #expect(!finished.value)
        #expect(!syncEngine.isValid(previous))
        let (settlement, settled) = await startSettlementWaiter()
        #expect(!settled.value)

        apply.open()
        await task.value
        let token = try await settlement.value
        #expect(syncEngine.isValid(token))
        #expect(settled.value)
        #expect(finished.value)
        try await expectTitle("Remote")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(
        $syncEngineDelegate.set(CompletionReportingDelegate()),
        arguments: [CKDatabase.Scope.private, .shared]
      )
      func terminalRollbackPrecedesReportAndFetchingWaitsForReport(
        scope: CKDatabase.Scope
      ) async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        delegate.reset()
        try await prepareRemoteUpdate(pending: true, scope: scope)
        let engine = syncEngine.syncEngine(for: scope)
        let previous = try await syncEngine.waitForSettlement()
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

        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        let finished = LockIsolated(false)
        let task = Task {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
          finished.setValue(true)
        }
        await apply.entered.wait()
        #expect(syncEngine.isFetchingChanges)
        #expect(delegate.errors.value.isEmpty)
        #expect(!finished.value)
        #expect(!syncEngine.isValid(previous))
        let (settlement, settled) = await startSettlementWaiter()
        #expect(!settled.value)

        apply.open()
        await delegate.entered.wait()
        #expect(delegate.queryTitle.value == "Local")
        #expect(delegate.queryFailure.value == nil)
        #expect(delegate.errors.value.count == 1)
        #expect(delegate.errors.value.first?.context.operationKind == .fetchedRecordApplication)
        #expect(delegate.errors.value.first?.context.disposition == .terminalDroppedOrReconciled)
        let errorDescription = delegate.errors.value.first.map { String(describing: $0.error) }
        #expect(errorDescription?.contains("completion test rollback") == true)
        #expect(syncEngine.isFetchingChanges)
        #expect(!finished.value)
        #expect(!delegate.finished.value)
        #expect(!settled.value)
        #expect(!syncEngine.isValid(previous))

        delegate.release.signal()
        await task.value
        let token = try await settlement.value
        #expect(syncEngine.isValid(token))
        #expect(settled.value)
        #expect(delegate.finished.value)
        try await expectTitle("Local")
        // A terminal application error leaves the retry marker in the current API.
        try await expectPendingCount(1)
        try await userDatabase.write { db in
          try UnsyncedRecordID.all.delete().execute(db)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(
        $syncEngineDelegate.set(CompletionReportingDelegate()),
        arguments: [CKDatabase.Scope.private, .shared]
      )
      func cancellationReportCanSuspendOnWriterQuery(scope: CKDatabase.Scope) async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        delegate.reset()
        let record = try await prepareRemoteUpdate(pending: false, scope: scope)
        let engine = syncEngine.syncEngine(for: scope)
        let previous = try await syncEngine.waitForSettlement()
        let query = CompletionSQLGate()
        let writer = userDatabase.database
        try await writer.write { db in
          db.add(
            function: DatabaseFunction("completion_query_gate", argumentCount: 0) { _ in
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
            syncEngine: engine
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
        #expect(!syncEngine.isValid(previous))
        let (settlement, settled) = await startSettlementWaiter()
        #expect(!settled.value)

        query.open()
        await delegate.entered.wait()
        #expect(delegate.queryTitle.value == "Local")
        #expect(delegate.queryFailure.value == nil)
        #expect(!settled.value)
        #expect(!syncEngine.isValid(previous))
        delegate.release.signal()
        await task.value
        let token = try await settlement.value
        #expect(syncEngine.isValid(token))
        #expect(settled.value)
        #expect(delegate.finished.value)
        // Settlement means callbacks completed, not that transient retries succeeded.
        try await expectPendingCount(1)

        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        #expect(!syncEngine.isValid(token))
        try await expectTitle("Remote")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func explicitFetchAwaitsApplyButDoesNotEstablishAStableEpoch(
        useSettlementBarrier: Bool
      ) async throws {
        try await prepareRemoteUpdate(pending: false)
        let explicitApply = CompletionSQLGate()
        try await installApplyGate(explicitApply)
        defer { explicitApply.open() }
        let returned = LockIsolated(false)
        let fetch = Task {
          let token: SyncEngine.SettledToken?
          if useSettlementBarrier {
            token = try await syncEngine.fetchChangesAndWaitForSettlement()
          } else {
            try await syncEngine.fetchChanges()
            token = nil
          }
          returned.setValue(true)
          return token
        }
        await explicitApply.entered.wait()
        // Do not mischaracterize fetchChanges: it does await its explicit callbacks.
        #expect(!returned.value)
        explicitApply.open()
        let token = try await fetch.value
        if let token { #expect(syncEngine.isValid(token)) }
        #expect(returned.value)
        try await expectTitle("Remote")

        let laterRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1))
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
        // A completed explicit fetch is not a stable completion epoch: a later automatic
        // fetch can already have an uncommitted final apply in flight.
        #expect(returned.value)
        #expect(syncEngine.isFetchingChanges)
        #expect(!automaticFinished.value)
        if let token { #expect(!syncEngine.isValid(token)) }
        automaticApply.open()
        await automatic.value
        try await expectTitle("Later automatic fetch")
        try await expectPendingCount(0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(
        $syncEngineDelegate.set(CompletionReportingDelegate()),
        arguments: [false, true]
      )
      func retiredCallbackBlocksRestartedSettlement(explicitFetch: Bool) async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        delegate.reset()
        try await prepareRemoteUpdate(pending: !explicitFetch)
        let previous = try await syncEngine.waitForSettlement()
        let oldEngine = syncEngine.private
        let apply = CompletionSQLGate()
        try await installApplyGate(apply, fail: true)
        defer {
          apply.open()
          delegate.release.signal()
        }
        if !explicitFetch {
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: oldEngine)
        }
        let operationFinished = LockIsolated(false)
        let operation = Task {
          defer { operationFinished.setValue(true) }
          if explicitFetch {
            _ = try await syncEngine.fetchChangesAndWaitForSettlement()
          } else {
            await syncEngine.handleEvent(.didFetchChanges, syncEngine: oldEngine)
          }
        }
        await apply.entered.wait()
        let (oldWaiter, oldSettled) = await startSettlementWaiter()
        #expect(!oldSettled.value)
        #expect(!syncEngine.isValid(previous))

        syncEngine.stop()
        await #expect(throws: CancellationError.self) { try await oldWaiter.value }
        #expect(!oldSettled.value)
        #expect(!operationFinished.value)

        // Restart reads the database synchronously. Release the writer into a still-
        // blocked error report, preserving the old callback without deadlocking start.
        apply.open()
        await delegate.entered.wait()
        #expect(!delegate.finished.value)
        try await syncEngine.start()
        #expect(syncEngine.private !== oldEngine)
        #expect(!syncEngine.isValid(previous))
        let (newWaiter, newSettled) = await startSettlementWaiter()
        #expect(!newSettled.value)
        #expect(!operationFinished.value)

        delegate.release.signal()
        if explicitFetch {
          // The explicit fetch does eventually return, but its lifetime was stopped.
          await #expect(throws: CancellationError.self) { try await operation.value }
        } else {
          try await operation.value
        }
        let token = try await newWaiter.value
        #expect(syncEngine.isValid(token))
        #expect(newSettled.value)
        #expect(delegate.finished.value)
        #expect(operationFinished.value)
        try await expectTitle("Local")
        try await userDatabase.write { db in
          try UnsyncedRecordID.all.delete().execute(db)
        }
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: ["fetch", "send", "sync", "fetchReceipt", "sendReceipt"])
      func drainWaitsForStartup(operation: String) async throws {
        syncEngine.stop()
        let gate = CompletionSQLGate()
        defer { gate.open() }
        try await userDatabase.database.write { db in
          db.add(
            function: DatabaseFunction("drain_start_gate", argumentCount: 0) { _ in
              gate.block()
              return 0
            })
          try db.execute(
            sql: """
              CREATE TEMP TRIGGER drain_start AFTER UPDATE ON sqlitedata_icloud_recordTypes
              BEGIN SELECT drain_start_gate(); END
              """)
        }
        let start = Task { try await syncEngine.start() }
        await gate.entered.wait()
        var explicit: Task<Void, any Error>!
        await withMainSerialExecutor {
          explicit = Task {
            switch operation {
            case "send": try await syncEngine.sendChanges()
            case "sync": try await syncEngine.syncChanges()
            case "fetchReceipt": _ = try await syncEngine.fetchChangesWithReceipt()
            case "sendReceipt": _ = try await syncEngine.sendChangesWithReceipt()
            default: try await syncEngine.fetchChanges()
            }
          }
          await Task.yield()
        }
        let finished = LockIsolated(false)
        var drain: Task<Void, any Error>!
        await withMainSerialExecutor {
          drain = Task {
            try await syncEngine.stopAndDrain()
            finished.setValue(true)
          }
          await Task.yield()
          #expect(!finished.value)
          #expect(!syncEngine.isRunning)
        }
        gate.open()
        try await start.value
        await #expect(throws: CancellationError.self) { try await explicit.value }
        try await drain.value
        #expect(finished.value)
        #expect(!syncEngine.isRunning)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopDuringAccountResetSuppressesRestart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        let gate = CompletionSQLGate()
        defer { gate.open() }
        try await userDatabase.database.write { db in
          db.add(
            function: DatabaseFunction("drain_reset_gate", argumentCount: 0) { _ in
              gate.block()
              return 0
            })
          try db.execute(
            sql: """
              CREATE TRIGGER drain_reset AFTER DELETE ON remindersLists
              BEGIN SELECT drain_reset_gate(); END
              """)
        }
        let old = syncEngine.private
        let callback = Task {
          await syncEngine.handleEvent(
            .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))),
            syncEngine: old)
        }
        await gate.entered.wait()
        #expect(!syncEngine.isRunning)
        var drain: Task<Void, any Error>!
        let finished = LockIsolated(false)
        await withMainSerialExecutor {
          drain = Task {
            try await syncEngine.stopAndDrain()
            finished.setValue(true)
          }
          await Task.yield()
          #expect(!finished.value)
        }
        gate.open()
        await callback.value
        try await drain.value
        #expect(!syncEngine.isRunning)
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(CompletionReportingDelegate()), arguments: [false, true])
      func drainWaitsForApplyAndReport(explicitFetch: Bool) async throws {
        let delegate = try #require(syncEngineDelegate as? CompletionReportingDelegate)
        delegate.reset()
        try await prepareRemoteUpdate(pending: !explicitFetch)
        let oldEngine = syncEngine.private
        let apply = CompletionSQLGate()
        try await installApplyGate(apply, fail: true)
        defer {
          apply.open()
          delegate.release.signal()
        }
        let operation = Task {
          if explicitFetch {
            try await syncEngine.fetchChanges()
          } else {
            await syncEngine.handleEvent(.didFetchChanges, syncEngine: oldEngine)
          }
        }
        await apply.entered.wait()
        let drained = LockIsolated(false)
        var drain: Task<Void, any Error>!
        await withMainSerialExecutor {
          drain = Task {
            try await syncEngine.stopAndDrain()
            drained.setValue(true)
          }
          await Task.yield()
          #expect(!syncEngine.isRunning)
          #expect(!drained.value)
        }
        await #expect(throws: CancellationError.self) { try await syncEngine.start() }
        apply.open()
        await delegate.entered.wait()
        #expect(!drained.value)
        delegate.release.signal()
        try await operation.value
        try await drain.value
        #expect(delegate.finished.value)
        #expect(drained.value)
        #expect(!syncEngine.isRunning)
        try await expectTitle("Local")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @discardableResult
      private func prepareRemoteUpdate(
        pending: Bool,
        scope: CKDatabase.Scope = .private
      ) async throws -> CKRecord {
        let recordID: CKRecord.ID
        if scope == .shared {
          let zoneID = CKRecordZone.ID(zoneName: "completion.shared", ownerName: "another.owner")
          recordID = RemindersList.recordID(for: 1, zoneID: zoneID)
          try await syncEngine.modifyRecordZones(
            scope: .shared, saving: [CKRecordZone(zoneID: zoneID)]
          ).notify()
          let initial = CKRecord(recordType: RemindersList.tableName, recordID: recordID)
          initial.setValue(1, forKey: "id", at: now)
          initial.setValue("Local", forKey: "title", at: now)
          let share = CKShare(
            rootRecord: initial,
            shareID: CKRecord.ID(recordName: "completion.share", zoneID: zoneID)
          )
          share.publicPermission = .readWrite
          let results = try await syncEngine.modifyRecords(
            scope: .shared, saving: [initial, share]
          ).notify()
          for result in results.saveResults.values { _ = try result.get() }
        } else {
          recordID = RemindersList.recordID(for: 1)
          try await userDatabase.userWrite { db in
            try db.seed { RemindersList(id: 1, title: "Local") }
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        let engine = syncEngine.syncEngine(for: scope)
        let record = try engine.database.record(for: recordID)
        record.setValue("Remote", forKey: "title", at: now + 1)
        _ = try syncEngine.modifyRecords(scope: scope, saving: [record])
        if pending {
          try await userDatabase.write { db in
            try UnsyncedRecordID.insert {
              UnsyncedRecordID(recordID: recordID)
            }.execute(db)
          }
        }
        return try engine.database.record(for: recordID)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func startSettlementWaiter() async -> (
        Task<SyncEngine.SettledToken, any Error>, LockIsolated<Bool>
      ) {
        let settled = LockIsolated(false)
        var waiter: Task<SyncEngine.SettledToken, any Error>!
        await withMainSerialExecutor {
          waiter = Task {
            let token = try await syncEngine.waitForSettlement()
            settled.setValue(true)
            return token
          }
          // Register the waiter while the SQL/delegate gate holds real work pending.
          await Task.yield()
          #expect(!settled.value)
        }
        return (waiter, settled)
      }

      private func installApplyGate(_ gate: CompletionSQLGate, fail: Bool = false) async throws {
        try await userDatabase.database.write { db in
          db.add(
            function: DatabaseFunction("completion_apply_gate", argumentCount: 0) { _ in
              gate.block()
              return 0
            })
          try db.execute(sql: "DROP TRIGGER IF EXISTS completion_apply")
          // AFTER UPDATE makes the terminal case prove rollback, not just a rejected write.
          try db.execute(
            sql: """
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
    private let gates = LockIsolated((entered: CompletionLatch(), release: CompletionLatch()))
    var entered: CompletionLatch { gates.value.entered }
    var release: CompletionLatch { gates.value.release }
    let finished = LockIsolated(false)

    /// The task-local trait shares its value across parameter cases. Cases are serialized
    /// and await their handler before returning, so each can start with fresh gates/state.
    func reset() {
      errors.setValue([])
      query.setValue(nil)
      queryTitle.setValue(nil)
      queryFailure.setValue(nil)
      gates.setValue((entered: CompletionLatch(), release: CompletionLatch()))
      finished.setValue(false)
    }

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
