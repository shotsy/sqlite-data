#if canImport(CloudKit)
  import Testing
  @testable import SQLiteData

  extension BaseCloudKitTests {
    @MainActor
    final class AccountResetOwnershipTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func inheritedWorkFromAnotherEngineDoesNotPreventReset() async throws {
        let other = try await BaseCloudKitTests()
        defer {
          syncEngine.stop()
          other.syncEngine.stop()
        }
        try await seedLocalData()
        try await other.userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Other engine") }
        }
        let work = try #require(syncEngine.admit())
        let originalEngine = syncEngine.private
        let otherOriginalEngine = other.syncEngine.private

        try await SyncEngine.$accountWork.withValue(work) {
          try await other.syncEngine.deleteLocalData()
        }

        #expect(work.active.value)
        #expect(syncEngine.private === originalEngine)
        #expect(other.syncEngine.private !== otherOriginalEngine)
        try await expectLocalCount(1)
        try await other.userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
        }
        syncEngine.finish(work)
        // Neither the receiving engine's fresh admission nor the inherited work may leak.
        _ = try await syncEngine.waitForSettlement()
        _ = try await other.syncEngine.waitForSettlement()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func finishedWorkInheritedByDelayedTaskAdmitsFreshReset() async throws {
        defer { syncEngine.stop() }
        try await seedLocalData()
        let work = try #require(syncEngine.admit())
        let confirmation = SyncStartup()
        let originalEngine = syncEngine.private
        // Like a delegate that returns after spawning a task to await user confirmation.
        let reset = SyncEngine.$accountWork.withValue(work) {
          Task {
            await confirmation.wait()
            #expect(SyncEngine.accountWork === work)
            #expect(!work.active.value)
            try await syncEngine.deleteLocalData()
          }
        }
        syncEngine.finish(work)
        confirmation.finish()
        try await reset.value

        #expect(syncEngine.isRunning)
        #expect(syncEngine.private !== originalEngine)
        try await expectLocalCount(0)
        _ = try await syncEngine.waitForSettlement()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func inheritedWorkFromPreviousLifetimeAdmitsFreshReset() async throws {
        defer { syncEngine.stop() }
        try await seedLocalData()
        let work = try #require(syncEngine.admit())
        syncEngine.stop()
        try await syncEngine.start()
        let originalEngine = syncEngine.private

        try await SyncEngine.$accountWork.withValue(work) {
          try await syncEngine.deleteLocalData()
        }

        #expect(work.active.value)
        #expect(syncEngine.private !== originalEngine)
        try await expectLocalCount(0)
        syncEngine.finish(work)
        _ = try await syncEngine.waitForSettlement()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func externalStopRejectsResetExplicitly(inheritWork: Bool) async throws {
        try await seedLocalData()
        let work = try #require(syncEngine.admit())
        syncEngine.stop()

        await SyncEngine.$accountWork.withValue(inheritWork ? work : nil) {
          await #expect(throws: CancellationError.self) {
            try await syncEngine.deleteLocalData()
          }
        }

        #expect(!syncEngine.isRunning)
        try await expectLocalCount(1)
        syncEngine.finish(work)
        try await syncEngine.stopAndDrain()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedLocalData() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local") }
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func expectLocalCount(_ count: Int) async throws {
        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == count)
        }
      }
    }
  }
#endif
