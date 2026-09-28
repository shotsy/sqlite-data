#if canImport(CloudKit)
  package import ConcurrencyExtras
  import Dependencies
  package import GRDB

  package struct UserDatabase {
    /// Count of write attempts rejected because the database was suspended. Lets tests
    /// prove a write was actually blocked by suspension before they resume.
    package static let suspendedWriteAttempts = LockIsolated(0)

    package let database: any DatabaseWriter
    package init(database: any DatabaseWriter) {
      self.database = database
    }

    var path: String {
      database.path
    }

    var configuration: Configuration {
      database.configuration
    }

    /// Waits out database suspension instead of failing.
    ///
    /// Apps that post `Database.suspendNotification` when backgrounded keep receiving
    /// CloudKit events, and every write then fails with GRDB's "Database is suspended"
    /// `SQLITE_ABORT`, or `SQLITE_INTERRUPT` for a statement that was in flight. Failing
    /// here makes the sync engine drop fetched changes that CloudKit will not redeliver.
    ///
    /// Waiting is safe because CKSyncEngine delivers events serially and SQLiteData awaits
    /// each handler (CKSyncEngine.h: "does not deliver the next event until the delegate
    /// finishes"), so no later `.stateUpdate` can persist a newer change token first. If the
    /// process dies while waiting, the old token is still on disk and CloudKit redelivers.
    /// The wait ends on resume or task cancellation. `SyncEngine.stop()` does not cancel
    /// in-flight handlers, so a handler blocked here finishes after the next resume.
    package func write<T: Sendable>(
      _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
      var interruptRetries = 0
      while true {
        do {
          return try await database.write { db in
            try $_isSynchronizingChanges.withValue(true) {
              try updates(db)
            }
          }
        } catch let error as DatabaseError
          where error.isSuspendedError
          || (error.resultCode == .SQLITE_INTERRUPT && interruptRetries < 3)
        {
          // Suspension waits indefinitely; a bare interrupt (suspension of an in-flight
          // statement, or an explicit `interrupt()`) gets a few tries so a repeatable
          // interrupt cannot stall the event stream forever.
          if error.isSuspendedError {
            Self.suspendedWriteAttempts.withValue { $0 += 1 }
          } else {
            interruptRetries += 1
          }
          // ponytail: fixed 500ms poll. Observe Database.resumeNotification instead
          // if this shows up in energy logs.
          try await Task.sleep(nanoseconds: 500_000_000)
        }
      }
    }

    package func read<T: Sendable>(
      _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
      try await database.read { db in
        try updates(db)
      }
    }

    @_disfavoredOverload
    package func write<T>(
      _ updates: (Database) throws -> T
    ) throws -> T {
      try database.write { db in
        try $_isSynchronizingChanges.withValue(true) {
          try updates(db)
        }
      }
    }

    @_disfavoredOverload
    package func read<T>(
      _ updates: (Database) throws -> T
    ) throws -> T {
      try database.read { db in
        try updates(db)
      }
    }
  }
  extension DatabaseError {
    /// GRDB's error for a write attempted while the database is suspended
    /// (`Database.checkForSuspensionViolation`). Covered by `SuspendedDatabaseSyncTests`.
    fileprivate var isSuspendedError: Bool {
      resultCode == .SQLITE_ABORT && message == "Database is suspended"
    }
  }
#endif
