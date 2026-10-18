#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dispatch
  import GRDB
  import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized)
    final class DrainCompatibilityTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func concurrentDrainWaitersShareCompletionDespiteCancellation() async throws {
        let record = try await remoteUpdate()
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 2, title: "Pending upload") }
        }
        let old = syncEngine.private
        let apply = DrainSQLGate()
        try await installApplyGate(apply)
        defer { apply.open() }
        let event = Task {
          await syncEngine.handleEvent(
            .fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: old)
        }
        await apply.entered.wait()
        let completions = LockIsolated(0)
        var waiters: [Task<Void, any Error>] = []
        await withMainSerialExecutor {
          for _ in 0..<3 {
            waiters.append(Task {
              try await syncEngine.stopAndDrain()
              completions.withValue { count in count += 1 }
            })
          }
          await Task.yield()
          #expect(!syncEngine.isRunning)
          #expect(completions.value == 0)
          waiters[0].cancel()
          await Task.yield()
          #expect(completions.value == 0)
        }
        await #expect(throws: CancellationError.self) { try await syncEngine.start() }
        apply.open()
        await event.value
        // A cancelled caller may throw or receive the shared result. It must not cancel
        // persistence or the other callers, nor report successful completion before apply.
        let cancelledResult = await waiters[0].result
        if case .failure(let error) = cancelledResult { #expect(error is CancellationError) }
        try await waiters[1].value
        try await waiters[2].value
        try await syncEngine.stopAndDrain()
        try await expectTitle("Remote")
        try await syncEngine.metadatabase.read { db in
          let changes = try PendingRecordZoneChange.select(\.pendingRecordZoneChange).fetchAll(db)
          #expect(changes == [.saveRecord(RemindersList.recordID(for: 2))])
        }
        #expect(!syncEngine.isRunning)
        try await syncEngine.start()
        try await syncEngine.sendChanges()
        #expect(
          try syncEngine.private.database.record(for: RemindersList.recordID(for: 2))
            .encryptedValues["title"] as? String == "Pending upload")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DrainCompatibilityDelegate()))
      func drainWaitsForAdmittedApplyAndErrorDelegate() async throws {
        let delegate = try #require(syncEngineDelegate as? DrainCompatibilityDelegate)
        let record = try await remoteUpdate()
        let old = syncEngine.private
        let apply = DrainSQLGate()
        try await installApplyGate(apply, fail: true)
        defer {
          apply.open()
          delegate.reportRelease.signal()
        }
        let event = Task {
          await syncEngine.handleEvent(
            .fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: old)
        }
        await apply.entered.wait()
        let completed = LockIsolated(false)
        var drain: Task<Void, any Error>!
        await withMainSerialExecutor {
          drain = Task {
            try await syncEngine.stopAndDrain()
            completed.setValue(true)
          }
          await Task.yield()
          #expect(!syncEngine.isRunning)
          #expect(!completed.value)
        }
        apply.open()
        await delegate.reportEntered.wait()
        #expect(!completed.value)
        #expect(!delegate.reportFinished.value)
        try await expectTitle("Local") // The failed transaction released the writer.
        delegate.reportRelease.signal()
        await event.value
        try await drain.value
        #expect(delegate.reportFinished.value)
        #expect(delegate.reports.value == 1)
        #expect(completed.value)
        try await expectTitle("Local")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true], [false, true])
      func lateCallbacksPreserveLegacyStopButNotExplicitDrain(
        explicitDrain: Bool, previouslyStopped: Bool
      ) async throws {
        let record = try await remoteUpdate()
        let old = syncEngine.private
        if previouslyStopped {
          syncEngine.stop()
          try await syncEngine.start()
        }
        if explicitDrain {
          try await syncEngine.stopAndDrain()
        } else {
          syncEngine.stop()
        }
        try await syncEngine.start()
        let replacement = syncEngine.private
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: old)
        try await expectTitle(explicitDrain ? "Local" : "Remote")
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(
            modifications: [], deletions: [(record.recordID, record.recordType)]), syncEngine: old)
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == (explicitDrain ? 1 : 0))
        }
        #expect(syncEngine.private === replacement)
        replacement.state.assertPendingRecordZoneChanges([])
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func ordinaryStopWhileFetchAwaitsStartupDoesNotFetchOldEngine() async throws {
        _ = try await remoteUpdate()
        syncEngine.stop()
        let startupGate = DrainSQLGate()
        try await userDatabase.write { db in
          db.add(function: DatabaseFunction("drain_compat_startup", argumentCount: 0) { _ in
            startupGate.block()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_compat_startup
            AFTER UPDATE ON sqlitedata_icloud_recordTypes
            BEGIN SELECT drain_compat_startup(); END
            """)
        }
        defer { startupGate.open() }
        let startup = Task { try await syncEngine.start() }
        await startupGate.entered.wait()
        let old = syncEngine.private
        let oldShared = syncEngine.shared
        let oldTag = old.state.changeTag.value
        let finished = LockIsolated(false)
        var fetch: Task<Void, any Error>!
        await withMainSerialExecutor {
          fetch = Task {
            try await syncEngine.fetchChanges()
            finished.setValue(true)
          }
          await Task.yield()
          #expect(!finished.value)
          syncEngine.stop()
        }
        startupGate.open()
        try await startup.value
        try await fetch.value
        #expect(finished.value)
        #expect(!syncEngine.isRunning)
        // Scopes alone cannot detect this: MockSyncEngine.fetchChanges does not record
        // them. An actual fetch would advance changeTag and apply the remote title.
        old.assertFetchChangesScopes([])
        oldShared.assertFetchChangesScopes([])
        #expect(old.state.changeTag.value == oldTag)
        try await expectTitle("Local")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DrainCompatibilityDelegate()), arguments: [false, true])
      func delayedAccountChildStillResetsWithoutDrain(ordinaryRestart: Bool) async throws {
        let delegate = try #require(syncEngineDelegate as? DrainCompatibilityDelegate)
        delegate.resetChildGates()
        _ = try await remoteUpdate()
        delegate.accountTarget.setValue(syncEngine)
        await syncEngine.handleEvent(
          .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))),
          syncEngine: syncEngine.private)
        await delegate.childEntered.wait()
        let child = try #require(delegate.child.value)
        defer {
          delegate.childRelease.signal()
          syncEngine.stop()
        }
        if ordinaryRestart {
          syncEngine.stop()
          try await syncEngine.start()
        }
        let beforeReset = syncEngine.private
        delegate.childRelease.signal()
        try await child.value
        #expect(syncEngine.isRunning)
        #expect(syncEngine.private !== beforeReset)
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(SyncMetadata.count().fetchOne(db) == 0)
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 0)
        }
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DrainCompatibilityDelegate()))
      func delayedAccountChildCannotResetRestartedOwner() async throws {
        let delegate = try #require(syncEngineDelegate as? DrainCompatibilityDelegate)
        _ = try await remoteUpdate()
        delegate.accountTarget.setValue(syncEngine)
        await syncEngine.handleEvent(
          .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))),
          syncEngine: syncEngine.private)
        await delegate.childEntered.wait()
        let child = try #require(delegate.child.value)
        defer { delegate.childRelease.signal() }
        // The delegate has returned; its unstructured child retains the account context.
        try await syncEngine.stopAndDrain()
        try await syncEngine.start()
        let replacement = syncEngine.private
        delegate.childRelease.signal()
        await #expect(throws: CancellationError.self) { try await child.value }
        #expect(syncEngine.private === replacement)
        try await expectTitle("Local")
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DrainCompatibilityDelegate()))
      func delayedAccountChildFromAnotherOwnerCanResetItsTarget() async throws {
        let delegate = try #require(syncEngineDelegate as? DrainCompatibilityDelegate)
        let other = try await BaseCloudKitTests()
        defer {
          delegate.childRelease.signal()
          syncEngine.stop()
          other.syncEngine.stop()
        }
        _ = try await remoteUpdate()
        try await other.userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Other owner") }
        }
        delegate.accountTarget.setValue(other.syncEngine)
        let otherOld = other.syncEngine.private
        await syncEngine.handleEvent(
          .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))),
          syncEngine: syncEngine.private)
        await delegate.childEntered.wait()
        let child = try #require(delegate.child.value)
        try await syncEngine.stopAndDrain()
        delegate.childRelease.signal()
        try await child.value
        #expect(other.syncEngine.isRunning)
        #expect(other.syncEngine.private !== otherOld)
        #expect(!syncEngine.isRunning)
        try await expectTitle("Local")
        try await other.userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func remoteUpdate() async throws -> CKRecord {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Remote", forKey: "title", at: now + 1)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])
        return try syncEngine.private.database.record(for: record.recordID)
      }

      private func installApplyGate(_ gate: DrainSQLGate, fail: Bool = false) async throws {
        try await userDatabase.database.write { db in
          db.add(function: DatabaseFunction("drain_compat_apply", argumentCount: 0) { _ in
            gate.block()
            return 0
          })
          try db.execute(sql: """
            CREATE TEMP TRIGGER drain_compat_apply AFTER UPDATE ON remindersLists
            BEGIN
              SELECT drain_compat_apply();
              \(fail ? "SELECT RAISE(ABORT, 'drain compatibility rollback');" : "")
            END
            """)
        }
      }

      private func expectTitle(_ title: String) async throws {
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == title)
        }
      }
    }
  }

  private final class DrainLatch: Sendable {
    private struct State {
      var signaled = false
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())
    func wait() async {
      await withCheckedContinuation { continuation in
        let ready = state.withValue { state in
          if state.signaled { return true }
          state.waiters.append(continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    }
    func signal() {
      let waiters = state.withValue { state in
        state.signaled = true
        let waiters = state.waiters
        state.waiters.removeAll()
        return waiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  private final class DrainSQLGate: Sendable {
    let entered = DrainLatch()
    private let semaphore = DispatchSemaphore(value: 0)
    private let opened = LockIsolated(false)
    func block() {
      entered.signal()
      if !opened.value { semaphore.wait() }
    }
    func open() {
      let first = opened.withValue { opened in
        let first = !opened
        opened = true
        return first
      }
      if first { semaphore.signal() }
    }
  }

  private final class DrainCompatibilityDelegate: SyncEngineDelegate {
    let reportEntered = DrainLatch()
    let reportRelease = DrainLatch()
    let reportFinished = LockIsolated(false)
    let reports = LockIsolated(0)
    private let childGates = LockIsolated((entered: DrainLatch(), release: DrainLatch()))
    var childEntered: DrainLatch { childGates.value.entered }
    var childRelease: DrainLatch { childGates.value.release }
    func resetChildGates() {
      childGates.setValue((entered: DrainLatch(), release: DrainLatch()))
      child.setValue(nil)
    }
    let accountTarget = LockIsolated<SyncEngine?>(nil)
    let child = LockIsolated<Task<Void, any Error>?>(nil)

    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      guard case .signOut = changeType, let target = accountTarget.value else { return }
      child.setValue(Task {
        childEntered.signal()
        await childRelease.wait()
        try await target.deleteLocalData()
      })
    }

    func syncEngine(
      _ syncEngine: SyncEngine, didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {
      reports.withValue { count in count += 1 }
      reportEntered.signal()
      await reportRelease.wait()
      reportFinished.setValue(true)
    }
  }
#endif
