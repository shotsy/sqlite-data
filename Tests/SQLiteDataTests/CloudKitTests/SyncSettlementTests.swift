#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  @testable import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
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
          #expect(!syncEngine.isValid(restarted))
          _ = try await syncEngine.waitForSettlement()
          syncEngine.stop()
        }
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
