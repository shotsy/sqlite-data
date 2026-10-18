#if canImport(CloudKit)
  public import CloudKit
  import CustomDump
  import IssueReporting

  /// The sync operation during which a reported ``SyncEngine`` error occurred.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public enum SyncEngineOperation: String, Sendable, Equatable {
    /// An explicit fetch of remote changes threw an error.
    case fetchChanges = "fetchChanges"
    /// An explicit send of local changes threw an error.
    case sendChanges = "sendChanges"
    /// CloudKit failed to save or delete a database zone.
    case sentDatabaseChanges = "sentDatabaseChanges"
    /// A CloudKit record-zone download completed with an error.
    case fetchRecordZoneChanges = "didFetchRecordZoneChanges"
    /// A locally-changed record failed to save to CloudKit.
    case sentRecordSave = "handleSentRecordZoneChanges.saveRecords"
    /// A locally-deleted record failed to delete from CloudKit.
    case sentRecordDelete = "handleSentRecordZoneChanges.deleteRecords"
    /// A record fetched from CloudKit failed to apply to the local database.
    case fetchedRecordApplication = "handleFetchedRecordZoneChanges.saveRecords"
    /// A deletion fetched from CloudKit failed to apply to the local database.
    case fetchedRecordDeletion = "handleFetchedRecordZoneChanges.deleteRecords"
    /// A CloudKit zone was deleted or purged.
    case zoneDeletion = "handleFetchedDatabaseChanges.deleteZone"
  }

  /// What the ``SyncEngine`` did about a reported error.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public enum SyncEngineErrorDisposition: Sendable, Equatable {
    /// The engine took corrective action (for example, merged a server record) and re-enqueued
    /// the change.
    case recoveredAndRetried
    /// The change remains pending and will be retried later (for example, after a backoff
    /// interval elapses).
    case transientPendingRetry
    /// The change was dropped or reconciled to the server's state and will not be retried
    /// automatically.
    case terminalDroppedOrReconciled
  }

  /// Context describing an internal ``SyncEngine`` error that was caught and reported by
  /// SQLiteData.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineErrorContext: Sendable {
    public let operation: String
    public let operationKind: SyncEngineOperation?
    /// The engine's recovery action, when known. Download reporting leaves this nil because
    /// it neither changes pending records nor makes a retry decision.
    public let disposition: SyncEngineErrorDisposition?
    /// The database in which the failure occurred, when known.
    public let databaseScope: CKDatabase.Scope?
    /// The zone whose download failed. Explicit database-wide fetches leave this nil.
    public let zoneID: CKRecordZone.ID?
    public let tableName: String?
    public let recordType: String?
    public let isRemoteDelete: Bool
    public let isLocalSaveFailure: Bool
    public let isLocalDeleteFailure: Bool

    /// Creates typed context. Scope and zone default to nil for existing record-application
    /// and upload callers; download reports populate them when CloudKit supplies that detail.
    public init(
      operation: SyncEngineOperation,
      disposition: SyncEngineErrorDisposition? = nil,
      tableName: String? = nil,
      recordType: String? = nil,
      isRemoteDelete: Bool = false,
      isLocalSaveFailure: Bool = false,
      isLocalDeleteFailure: Bool = false,
      databaseScope: CKDatabase.Scope? = nil,
      zoneID: CKRecordZone.ID? = nil
    ) {
      self.databaseScope = databaseScope
      self.zoneID = zoneID
      self.operation = operation.rawValue
      self.operationKind = operation
      self.disposition = disposition
      self.tableName = tableName
      self.recordType = recordType
      self.isRemoteDelete = isRemoteDelete
      self.isLocalSaveFailure = isLocalSaveFailure
      self.isLocalDeleteFailure = isLocalDeleteFailure
    }

    /// Creates context for a string operation, retaining compatibility with custom operations.
    /// Known operation raw values also populate `operationKind`.
    public init(
      operation: String,
      tableName: String? = nil,
      recordType: String? = nil,
      isRemoteDelete: Bool = false,
      isLocalSaveFailure: Bool = false,
      isLocalDeleteFailure: Bool = false,
      databaseScope: CKDatabase.Scope? = nil,
      zoneID: CKRecordZone.ID? = nil
    ) {
      self.databaseScope = databaseScope
      self.zoneID = zoneID
      self.operation = operation
      self.operationKind = SyncEngineOperation(rawValue: operation)
      self.disposition = nil
      self.tableName = tableName
      self.recordType = recordType
      self.isRemoteDelete = isRemoteDelete
      self.isLocalSaveFailure = isLocalSaveFailure
      self.isLocalDeleteFailure = isLocalDeleteFailure
    }
  }

  /// Context emitted before a remote zone deletion or purge is mirrored into local storage.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineZoneDeletionContext: Sendable {
    public let zoneID: CKRecordZone.ID
    public let reason: CKDatabase.DatabaseChange.Deletion.Reason
    public let recordCountsByType: [String: Int]

    public init(
      zoneID: CKRecordZone.ID,
      reason: CKDatabase.DatabaseChange.Deletion.Reason,
      recordCountsByType: [String: Int]
    ) {
      self.zoneID = zoneID
      self.reason = reason
      self.recordCountsByType = recordCountsByType
    }
  }

  /// App-owned identity captured synchronously before a transfer starts. Rotate the window on
  /// stop/restart and the account token on identity changes; never bind an old token to a new account.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineTransferContext: Sendable, Equatable {
    public let accountToken: UUID
    public let windowToken: UUID

    public init(accountToken: UUID, windowToken: UUID) {
      self.accountToken = accountToken
      self.windowToken = windowToken
    }
  }

  /// Historical server-version evidence, not an inventory or proof of current local-row equality.
  /// Identity includes the container, database scope and full record ID (including zone owner).
  /// Change tags are opaque: never compare them across records/accounts or substitute SQL counts
  /// or modification times. Retained coverage requires the app's complete exact-version inventory.
  /// These identifiers are for local validation, not analytics; no record payload is exposed.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineRecordVersion: Sendable, Equatable {
    public let recordID: CKRecord.ID
    public let recordType: CKRecord.RecordType
    public let changeTag: String
    public let userModificationTime: Int64

    init?(_ record: CKRecord) {
      guard let tag = record.recordChangeTag, record.userModificationTime >= 0 else { return nil }
      recordID = record.recordID
      recordType = record.recordType
      changeTag = tag
      userModificationTime = record.userModificationTime
    }
  }

  /// Final diagnostic result for one originating engine transfer, delivered before its idle edge.
  /// Only acknowledged saves and exactly applied, committed fetches appear in `records` (including
  /// partial evidence on failure). Prepared, deleted, skipped, merged and deferred rows do not.
  /// Empty completed fetches may advance download time, never account confirmation. No result
  /// proves complete retained-version coverage by itself. Missing origin/boundaries or overlapping
  /// same-engine work is unconfirmed; callers must reject stale app-owned contexts independently.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineTransferOutcome: Sendable {
    public enum Direction: Sendable { case upload, download }
    public enum Result: Sendable { case completed, failed, interrupted, unconfirmed }
    public let context: SyncEngineTransferContext?
    public let containerIdentifier: String?
    public let databaseScope: CKDatabase.Scope
    public let direction: Direction
    public let result: Result
    public let records: [SyncEngineRecordVersion]
  }

  /// An interface for observing ``SyncEngine`` events and customizing ``SyncEngine`` behavior.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// An event indicating a change to the device's iCloud account.
    ///
    /// By default, a sync engine will clear out local data when detecting a logout or account
    /// change. To override this behavior, _e.g._ if you want to prompt the user and let them decide
    /// if they want to clear their local data or not, implement this method, and explicitly call
    /// ``SyncEngine/deleteLocalData()`` if/when the data should be cleared.
    ///
    /// For example, an observable model could override this method to set up some alert state:
    ///
    /// ```swift
    /// @MainActor
    /// @Observable
    /// class MySyncEngineDelegate: SyncEngineDelegate {
    ///   var isResetDataAlertPresented = false
    ///
    ///   func syncEngine(
    ///     _ syncEngine: SyncEngine,
    ///     accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ///   ) {
    ///     switch changeType {
    ///     case .signOut, .switchAccounts:
    ///       isResetDataAlertPresented = true
    ///     case .signIn:
    ///       break
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// And then SwiftUI could drive an alert with this state:
    ///
    /// ```swift
    /// struct MyApp: App {
    ///   @State var syncEngineDelegate = MySyncEngineDelegate()
    ///
    ///   init() {
    ///     prepareDependencies {
    ///       try! $0.bootstrapDatabase(syncEngineDelegate: syncEngineDelegate)
    ///     }
    ///   }
    ///
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       MyRootView()
    ///         .alert(
    ///           "Reset local data?",
    ///           isPresented: $syncEngineDelegate.isDeleteLocalDataAlertPresented
    ///         ) {
    ///           Button("Reset", role: .destructive) {
    ///             Task {
    ///               try await syncEngine.deleteLocalData()
    ///             }
    ///           }
    ///         } message: {
    ///           Text(
    ///             """
    ///             You are no longer logged into iCloud. Would you like to reset your local data \
    ///             to the defaults? This will not affect your data in iCloud.
    ///             """
    ///           )
    ///         }
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - changeType: The iCloud account's change type.
    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async

    /// Called when SQLiteData catches and reports an internal CloudKit sync error.
    ///
    /// SQLiteData may recover from or swallow these errors after reporting them via
    /// `withErrorReporting`. This hook lets applications mirror important failures into their own
    /// telemetry pipelines without changing sync behavior.
    ///
    /// Download errors are also delivered here, before a zone's fetching activity ends. Explicit
    /// fetches still throw the original error (including cancellation) after awaiting this hook.
    /// Their disposition is nil: reporting does not decide CloudKit's retry policy.
    ///
    /// Within an explicit fetch on one engine, an error equal under `NSError.isEqual` to an
    /// already-reported zone error is not reported again by the throwing path. That path awaits
    /// the zone report's completion. Distinct errors (including unequal partial-error wrappers),
    /// other engines, and later fetch attempts are not deduplicated. Events arriving only after
    /// the explicit call finishes are independent reports; no time-based suppression is used.
    func syncEngine(
      _ syncEngine: SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async

    /// An epoch-bound failure observation, including standalone automatic fetch/send cycles.
    /// Awaited outside database writers; the default is a no-op. Automatic epochs are conservative
    /// lifecycle windows, not unique CloudKit request IDs. Overlap may report a failure for multiple
    /// epochs. Captured callbacks retain their original epoch across awaits and lifecycle endings.
    /// There is no automatic success callback; use the explicit receipt APIs for settled success.
    func syncEngine(
      _ syncEngine: SyncEngine, didReportFailure failure: SyncEngine.AttemptReceipt.Failure)
      async

    /// Capture app identity without suspension. Return nil when identity/coverage is unavailable.
    /// Called before async transfer work; implementations must not call back into this engine.
    func syncEngine(
      _ syncEngine: SyncEngine, transferContextFor databaseScope: CKDatabase.Scope
    ) -> SyncEngineTransferContext?

    /// Observes immutable transfer evidence. Default is a no-op; never infer success from idle.
    func syncEngine(_ syncEngine: SyncEngine, didFinishTransfer outcome: SyncEngineTransferOutcome)
      async

    /// Called before a remote zone deletion or purge is mirrored into a broad local delete.
    func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteLocalRecords context: SyncEngineZoneDeletionContext
    ) async
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngineDelegate {
    public func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      switch changeType {
      case .signOut, .switchAccounts:
        await withErrorReporting {
          try await syncEngine.deleteLocalData()
        }
      case .signIn:
        break
      @unknown default:
        break
      }
    }

    public func syncEngine(
      _ syncEngine: SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
    ) async {}

    public func syncEngine(
      _ syncEngine: SyncEngine, didReportFailure failure: SyncEngine.AttemptReceipt.Failure
    ) async {}

    public func syncEngine(
      _ syncEngine: SyncEngine, transferContextFor databaseScope: CKDatabase.Scope
    ) -> SyncEngineTransferContext? { nil }

    public func syncEngine(
      _ syncEngine: SyncEngine, didFinishTransfer outcome: SyncEngineTransferOutcome
    ) async {}

    public func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteLocalRecords context: SyncEngineZoneDeletionContext
    ) async {}
  }
#endif
