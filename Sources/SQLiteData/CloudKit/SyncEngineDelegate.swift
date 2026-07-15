#if canImport(CloudKit)
  public import CloudKit
  import CustomDump
  import IssueReporting

  /// Context describing an internal ``SyncEngine`` error that was caught and reported by
  /// SQLiteData.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncEngineErrorContext: Sendable {
    public let operation: String
    public let tableName: String?
    public let recordType: String?
    public let isRemoteDelete: Bool
    public let isLocalSaveFailure: Bool
    public let isLocalDeleteFailure: Bool

    public init(
      operation: String,
      tableName: String? = nil,
      recordType: String? = nil,
      isRemoteDelete: Bool = false,
      isLocalSaveFailure: Bool = false,
      isLocalDeleteFailure: Bool = false
    ) {
      self.operation = operation
      self.tableName = tableName
      self.recordType = recordType
      self.isRemoteDelete = isRemoteDelete
      self.isLocalSaveFailure = isLocalSaveFailure
      self.isLocalDeleteFailure = isLocalDeleteFailure
    }
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
    func syncEngine(
      _ syncEngine: SyncEngine,
      didReportError error: any Error,
      context: SyncEngineErrorContext
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
  }
#endif
