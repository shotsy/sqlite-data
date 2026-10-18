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
    @Suite(.serialized)
    final class SyncSettlementTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [CKDatabase.Scope.private, .shared])
      func automaticFetchDuringAccountAwait(_ scope: CKDatabase.Scope) async throws {
        let token = try await syncEngine.fetchChangesAndWaitForSettlement()
        #expect(syncEngine.isValid(token))
        let accountEntered = SettlementLatch()
        let accountReleased = SettlementLatch()
        // The app's authoritative account-status adapter is deliberately suspended here.
        let accountStatus: @Sendable () async throws -> CKAccountStatus = { [container] in
          accountEntered.signal()
          await accountReleased.wait()
          return try await container.accountStatus()
        }
        let finalization = Task {
          let status = try await accountStatus()
          // Even when the account still looks available, the old fetch evidence is stale.
          #expect(status == .available)
          return syncEngine.isValid(token)
        }
        await accountEntered.wait()
        let engine = syncEngine.syncEngine(for: scope)
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        accountReleased.signal()
        let valid = try await finalization.value
        #expect(!valid)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        #expect(!syncEngine.isValid(token))
        let next = try await syncEngine.waitForSettlement()
        #expect(syncEngine.isValid(next))
        #expect(next != token)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func bothScopesAndNestedZonesMustDrain() async throws {
        try await withMainSerialExecutor {
          let privateEngine = syncEngine.private
          let sharedEngine = syncEngine.shared
          let zone = CKRecordZone.ID(zoneName: "settlement")
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: privateEngine)
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: sharedEngine)
          await syncEngine.handleEvent(
            .willFetchRecordZoneChanges(zoneID: zone), syncEngine: sharedEngine)
          let finished = LockIsolated(false)
          let waiter = Task {
            let token = try await syncEngine.waitForSettlement()
            finished.setValue(true)
            return token
          }
          await Task.yield()
          #expect(!finished.value)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: privateEngine)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: privateEngine)
          await Task.yield()
          #expect(!finished.value)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: sharedEngine)
          await Task.yield()
          #expect(!finished.value)
          await syncEngine.handleEvent(
            .didFetchRecordZoneChanges(zoneID: zone, error: nil), syncEngine: sharedEngine)
          let result = await waiter.result
          let token = try result.get()
          #expect(syncEngine.isValid(token))
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cancellationDoesNotStopSynchronization() async throws {
        try await withMainSerialExecutor {
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
          let waiter = Task { try await syncEngine.waitForSettlement() }
          await Task.yield()
          waiter.cancel()
          await #expect(throws: CancellationError.self) { try await waiter.value }
          #expect(syncEngine.isRunning)
          #expect(syncEngine.isFetchingChanges)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
          let token = try await syncEngine.waitForSettlement()
          #expect(syncEngine.isValid(token))
          let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await syncEngine.waitForSettlement()
          }
          await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopInvalidatesTokensAndWakesAllWaiters() async throws {
        try await withMainSerialExecutor {
          let token = try await syncEngine.waitForSettlement()
          let oldEngine = syncEngine.private
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: oldEngine)
          let waits = (0..<3).map { _ in Task { try await syncEngine.waitForSettlement() } }
          await Task.yield()
          syncEngine.stop()
          #expect(!syncEngine.isValid(token))
          for waiter in waits {
            await #expect(throws: CancellationError.self) { try await waiter.value }
          }
          await #expect(throws: CancellationError.self) { try await syncEngine.waitForSettlement() }
          await #expect(throws: CancellationError.self) {
            try await syncEngine.fetchChangesAndWaitForSettlement()
          }
          try await syncEngine.start()
          let restarted = try await syncEngine.waitForSettlement()
          #expect(syncEngine.isValid(restarted))
          #expect(!syncEngine.isValid(token))
          // Retired lifecycle notifications do not strand the new engine's waiters.
          await syncEngine.handleEvent(.willFetchChanges, syncEngine: oldEngine)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: oldEngine)
          #expect(syncEngine.isValid(restarted))
          _ = try await syncEngine.waitForSettlement()
          syncEngine.stop()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: ["event", "account", "stop", "drain"])
      func leaseExcludesConcurrentInvalidation(_ kind: String) async throws {
        let token = try await syncEngine.waitForSettlement()
        let engine = syncEngine.private
        let entered = SettlementLatch()
        let release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = LockIsolated<Result<Int, any Error>?>(nil)
        let leaseFinished = SettlementLatch()
        // Use a real thread: other suites temporarily install the main serial executor globally.
        DispatchQueue.global().async { [syncEngine] in
          result.setValue(
            Result {
              try syncEngine.withSettlementLease(token) {
                entered.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
                return 42
              }
            })
          leaseFinished.signal()
        }
        await entered.wait()
        DispatchQueue.global().async {
          #expect(attempted.wait(timeout: .now() + 5) == .success)
          #expect(completed.wait(timeout: .now() + 0.05) == .timedOut)
          release.signal()
        }
        let event = Task { [syncEngine] in
          attempted.signal()
          switch kind {
          case "stop": syncEngine.stop()
          case "drain": try await syncEngine.stopAndDrain()
          case "account":
            await syncEngine.handleEvent(
              .accountChange(changeType: .signIn(currentUser: CKRecord.ID(recordName: "user"))),
              syncEngine: engine
            )
          default:
            await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
          }
          completed.signal()
        }
        await leaseFinished.wait()
        #expect(try result.value?.get() == 42)
        try await event.value
        #expect(!syncEngine.isValid(token))
        if kind == "account" {
          try await syncEngine.processPendingDatabaseChanges(scope: .private)
        }
        if kind == "event" {
          // The blocked event was delivered, not discarded by the lease.
          #expect(syncEngine.isFetchingChanges)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
          _ = try await syncEngine.waitForSettlement()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func leasePersistenceDoesNotBlockWriterBehindAdmission(stopping: Bool) async throws {
        let token = try await syncEngine.waitForSettlement()
        let engine = syncEngine.private
        let writer = userDatabase.database
        let writerEntered = DispatchSemaphore(value: 0)
        let admissionAttempted = DispatchSemaphore(value: 0)
        let leaseEntered = SettlementLatch()
        let writerFinished = SettlementLatch()
        let leaseFinished = SettlementLatch()
        let startConsumer = DispatchSemaphore(value: 0)
        // A genuine writer transaction runs the same synchronous trigger callback as a local edit.
        DispatchQueue.global().async { [syncEngine] in
          do {
            try writer.write { _ in
              writerEntered.signal()
              #expect(admissionAttempted.wait(timeout: .now() + 5) == .success)
              Thread.sleep(forTimeInterval: 0.05)
              syncEngine.didUpdate(
                recordName: "lease-test:remindersLists", zoneName: "zone",
                ownerName: CKCurrentUserDefaultName, oldZoneName: "zone",
                oldOwnerName: CKCurrentUserDefaultName, descendantRecordNames: nil
              )
            }
          } catch { Issue.record(error) }
          writerFinished.signal()
        }
        DispatchQueue.global().async { [syncEngine] in
          do {
            try syncEngine.withSettlementLease(token) {
              #expect(writerEntered.wait(timeout: .now() + 5) == .success)
              leaseEntered.signal()
              #expect(startConsumer.wait(timeout: .now() + 5) == .success)
              try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS lease_receipt (id INTEGER)")
                try db.execute(sql: "INSERT INTO lease_receipt VALUES (1)")
              }
            }
          } catch { Issue.record(error) }
          leaseFinished.signal()
        }
        await leaseEntered.wait()
        let event = Task { [syncEngine] in
          admissionAttempted.signal()
          startConsumer.signal()
          if stopping {
            syncEngine.stop()
          } else {
            await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
          }
        }
        await writerFinished.wait()
        await leaseFinished.wait()
        await event.value
        #expect(
          try await writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lease_receipt") }
            == 1)
        engine.state.remove(pendingRecordZoneChanges: [
          .saveRecord(
            CKRecord.ID(
              recordName: "lease-test:remindersLists", zoneID: CKRecordZone.ID(zoneName: "zone")))
        ])
        if !stopping {
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func throwingConsumerReleasesLeaseAndPropagatesError() async throws {
        struct ConsumerFailure: Error, Equatable { let value: Int }
        let token = try await syncEngine.waitForSettlement()
        #expect(throws: ConsumerFailure(value: 42)) {
          try syncEngine.withSettlementLease(token) { throw ConsumerFailure(value: 42) }
        }
        #expect(try syncEngine.withSettlementLease(token) { "retry" } == "retry")
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        let invoked = LockIsolated(false)
        #expect(throws: CancellationError.self) {
          try syncEngine.withSettlementLease(token) { invoked.setValue(true) }
        }
        #expect(!invoked.value)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func retiredMutationsAreRejected(restart: Bool) async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let old = syncEngine.private
        let recordID = RemindersList.recordID(for: 1)
        let record = try old.database.record(for: recordID)
        record.setValue("Retired", forKey: "title", at: now + 1)
        syncEngine.stop()
        if restart { try await syncEngine.start() }
        let token = restart ? try await syncEngine.waitForSettlement() : nil
        let events: [SQLiteData.SyncEngine.Event] = [
          .fetchedRecordZoneChanges(modifications: [record], deletions: []),
          .fetchedRecordZoneChanges(
            modifications: [], deletions: [(recordID, RemindersList.tableName)]),
          .fetchedDatabaseChanges(modifications: [], deletions: [(recordID.zoneID, .deleted)]),
          .sentRecordZoneChanges(
            savedRecords: [record], failedRecordSaves: [], deletedRecordIDs: [],
            failedRecordDeletes: [:]),
          .sentRecordZoneChanges(
            savedRecords: [], failedRecordSaves: [(record, CKError(.quotaExceeded))],
            deletedRecordIDs: [], failedRecordDeletes: [recordID: CKError(.permissionFailure)]),
          .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old-user"))),
        ]
        for event in events { await syncEngine.handleEvent(event, syncEngine: old) }
        // Package seams must enforce the same admission rule as SDK entry points.
        await syncEngine.handleFetchedRecordZoneChanges(modifications: [record], syncEngine: old)
        await syncEngine.handleSentRecordZoneChanges(deletedRecordIDs: [recordID], syncEngine: old)
        old.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        #expect(await syncEngine.nextRecordZoneChangeBatch(syncEngine: old) == nil)
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Local")
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(DurableRecordZoneFailure.count().fetchOne(db) == 0)
        }
        if let token { #expect(syncEngine.isValid(token)) }
        #expect(syncEngine.isRunning == restart)
        old.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func retiredRetryCannotEnqueueIntoRestart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
        let old = syncEngine.private
        let recordID = RemindersList.recordID(for: 1)
        old.database.failNextSave(for: recordID, with: .quotaExceeded)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        await Task.yield()
        syncEngine.stop()
        // Remove the durable failure so startup does not schedule a new, legitimate retry.
        try await userDatabase.write { db in
          try DurableRecordZoneFailure.delete().execute(db)
        }
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await userDatabase.write { db in
          try DurableRecordZoneFailure.insert {
            DurableRecordZoneFailure(
              recordID: recordID, action: DurableRecordZoneFailure.saveAction,
              recordType: RemindersList.tableName, errorCode: .quotaExceeded,
              attemptCount: 1, isTerminal: false)
          }.execute(db)
        }
        await testClock.advance(by: .seconds(30))
        await Task.yield()
        _ = try await syncEngine.waitForSettlement()
        #expect(old.state.pendingRecordZoneChanges.isEmpty)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DrainAccountDelegate()), arguments: [false, true])
      func accountCallbackCannotRestartAfterExternalStop(drain: Bool) async throws {
        let delegate = try #require(syncEngineDelegate as? DrainAccountDelegate)
        delegate.reset()
        let callback = Task {
          await syncEngine.handleEvent(
            .accountChange(changeType: .signOut(previousUser: CKRecord.ID(recordName: "old"))),
            syncEngine: syncEngine.private)
        }
        await delegate.entered.wait()
        var barrier: Task<Void, any Error>!
        await withMainSerialExecutor {
          if drain {
            barrier = Task { try await syncEngine.stopAndDrain() }
            await Task.yield()
          } else {
            syncEngine.stop()
          }
          #expect(!syncEngine.isRunning)
        }
        delegate.release.signal()
        await callback.value
        try await barrier?.value
        #expect(!syncEngine.isRunning)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func concurrentCancelledDrainsCloseAdmission() async throws {
        try await withMainSerialExecutor {
          let work = try #require(syncEngine.admit())
          let finished = LockIsolated(0)
          syncEngine.stop()
          let drains = (0..<2).map { _ in
            Task {
              try await syncEngine.stopAndDrain()
              finished.withValue { $0 += 1 }
            }
          }
          await Task.yield()
          drains[0].cancel()
          #expect(!syncEngine.isRunning)
          #expect(finished.value == 0)
          await #expect(throws: CancellationError.self) { try await syncEngine.start() }
          syncEngine.finish(work)
          for drain in drains { try await drain.value }
          #expect(finished.value == 2)
          try await syncEngine.start()
          #expect(syncEngine.isRunning)
          syncEngine.stop()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stoppedTriggerPersistenceIsDrained() async throws {
        let work = try #require(syncEngine.admit())
        syncEngine.stop()
        syncEngine.didUpdate(
          recordName: "drain:remindersLists", zoneName: "zone",
          ownerName: CKCurrentUserDefaultName, oldZoneName: "zone",
          oldOwnerName: CKCurrentUserDefaultName, descendantRecordNames: nil)
        syncEngine.finish(work)
        try await syncEngine.stopAndDrain()
        try await syncEngine.metadatabase.read { db in
          try #expect(PendingRecordZoneChange.count().fetchOne(db) == 1)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unmatchedLifecycleDoesNotStrandDrain() async throws {
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        try await syncEngine.stopAndDrain()
        #expect(!syncEngine.isRunning)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func tokenCannotBeUsedOnAnotherEngine() async throws {
        let token = try await syncEngine.waitForSettlement()
        let other = SyncSettlement()
        _ = other.start()
        #expect(!other.isValid(token))
        let otherToken = try await other.wait()
        #expect(!syncEngine.isValid(otherToken))
      }
    }
  }

  private final class DrainAccountDelegate: SyncEngineDelegate {
    private let gates = LockIsolated((entered: SettlementLatch(), release: SettlementLatch()))
    var entered: SettlementLatch { gates.value.entered }
    var release: SettlementLatch { gates.value.release }
    func reset() { gates.setValue((entered: SettlementLatch(), release: SettlementLatch())) }
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      guard case .signOut = changeType else { return }
      entered.signal()
      await release.wait()
      await #expect(throws: CancellationError.self) { try await syncEngine.deleteLocalData() }
    }
  }

  private final class SettlementLatch: Sendable {
    private struct State {
      var signaled = false
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())
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
#endif
