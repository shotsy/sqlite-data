#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Observation
  import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite
    final class SyncEngineActivityTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func concurrentCallbacks() async {
        let wrapper = syncEngine
        let engines = [syncEngine.private, syncEngine.shared]
        await withTaskGroup(of: Void.self) { group in
          for index in 0..<100 {
            group.addTask {
              await wrapper.updateActivity(
                .sending, isStarting: true, syncEngine: engines[index % 2]
              )
              await wrapper.handleEvent(.willFetchChanges, syncEngine: engines[index % 2])
            }
          }
        }
        await withTaskGroup(of: Void.self) { group in
          for index in 0..<98 {
            group.addTask {
              await wrapper.updateActivity(
                .sending, isStarting: false, syncEngine: engines[index % 2]
              )
              await wrapper.handleEvent(.didFetchChanges, syncEngine: engines[index % 2])
            }
          }
        }
        #expect(syncEngine.isSendingChanges)
        #expect(syncEngine.isFetchingChanges)
        for engine in engines {
          syncEngine.updateActivity(.sending, isStarting: false, syncEngine: engine)
          await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        }
        #expect(!syncEngine.isSynchronizing)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopNotifiesActivityObservers() {
        syncEngine.updateActivity(.sending, isStarting: true, syncEngine: syncEngine.private)
        syncEngine.updateActivity(.fetching, isStarting: true, syncEngine: syncEngine.shared)
        let sendingChanged = LockIsolated(false)
        let fetchingChanged = LockIsolated(false)
        withObservationTracking {
          _ = syncEngine.isSendingChanges
        } onChange: {
          sendingChanged.setValue(true)
        }
        withObservationTracking {
          _ = syncEngine.isFetchingChanges
        } onChange: {
          fetchingChanged.setValue(true)
        }
        syncEngine.stop()
        #expect(sendingChanged.value)
        #expect(fetchingChanged.value)
        #expect(!syncEngine.isSynchronizing)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopClearsActivity() async throws {
        let oldEngine = syncEngine.private
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: oldEngine)
        #expect(syncEngine.isFetchingChanges)
        syncEngine.stop()
        #expect(!syncEngine.isFetchingChanges)
        #expect(!syncEngine.isSynchronizing)
        try await syncEngine.start()
        #expect(!syncEngine.isFetchingChanges)
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [
        SyncEngine.Activity.sending,
        .fetching,
        .fetchingZone(CKRecordZone.ID(zoneName: "activity")),
      ])
      func activityLifecycle(_ activity: SyncEngine.Activity) async throws {
        let oldPrivate = syncEngine.private
        let oldShared = syncEngine.shared
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: oldPrivate)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: oldShared)
        #expect(syncEngine.isSynchronizing)
        #expect(syncEngine.isSendingChanges == (activity == .sending))
        #expect(syncEngine.isFetchingChanges == (activity != .sending))
        syncEngine.stop()
        #expect(!syncEngine.isSendingChanges)
        #expect(!syncEngine.isFetchingChanges)
        // Neither starts nor completions from retired engines revive stopped activity.
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: oldPrivate)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: oldShared)
        syncEngine.stop()
        #expect(!syncEngine.isSynchronizing)

        try await syncEngine.start()
        let current = syncEngine.private
        #expect(!syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: current)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: oldPrivate)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: oldShared)
        #expect(syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: oldPrivate)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: current)
        #expect(!syncEngine.isSynchronizing)
        syncEngine.stop()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [
        SyncEngine.Activity.sending,
        .fetching,
        .fetchingZone(CKRecordZone.ID(zoneName: "activity")),
      ])
      func overlappingActivity(_ activity: SyncEngine.Activity) {
        let privateEngine = syncEngine.private
        let sharedEngine = syncEngine.shared
        // An unmatched completion must not make the next start invisible.
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: privateEngine)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: privateEngine)
        #expect(syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: privateEngine)
        // A completion on the other engine must not consume private work.
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: sharedEngine)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: privateEngine)
        #expect(syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: true, syncEngine: sharedEngine)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: privateEngine)
        #expect(syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: privateEngine)
        #expect(syncEngine.isSynchronizing)
        syncEngine.updateActivity(activity, isStarting: false, syncEngine: sharedEngine)
        #expect(!syncEngine.isSynchronizing)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func nestedFetchEvents() async {
        let engine = syncEngine.private
        let zoneA = CKRecordZone.ID(zoneName: "a")
        let zoneB = CKRecordZone.ID(zoneName: "b")
        await syncEngine.handleEvent(.willFetchChanges, syncEngine: engine)
        // Unknown zone completions cannot consume the enclosing fetch.
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneB, error: nil), syncEngine: engine
        )
        #expect(syncEngine.isFetchingChanges)
        await syncEngine.handleEvent(.willFetchRecordZoneChanges(zoneID: zoneA), syncEngine: engine)
        await syncEngine.handleEvent(.willFetchRecordZoneChanges(zoneID: zoneB), syncEngine: engine)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: engine)
        #expect(syncEngine.isFetchingChanges)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneA, error: nil), syncEngine: engine
        )
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneA, error: nil), syncEngine: engine
        )
        #expect(syncEngine.isFetchingChanges)
        await syncEngine.handleEvent(
          .didFetchRecordZoneChanges(zoneID: zoneB, error: CKError(.networkFailure)),
          syncEngine: engine
        )
        #expect(!syncEngine.isSynchronizing)
      }
    }
  }
#endif
