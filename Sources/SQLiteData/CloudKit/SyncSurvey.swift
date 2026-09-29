#if canImport(CloudKit)
  public import CloudKit
  public import GRDB

  /// What a survey run is bound to. Any change discards the run's progress.
  public struct SyncSurveyRunIdentity: Codable, Hashable, Sendable {
    public var containerIdentifier: String
    public var environment: String
    public var userRecordName: String
    public var zoneName: String
    public var zoneOwnerName: String
    public var databaseGeneration: Int
    public var surveyVersion: Int
  }

  /// Run states reported while surveying. A thrown error is the caller's `failed` state.
  public enum SyncSurveyRunState: String, Sendable {
    case started, resumed, completed
  }

  /// The app's answer for whether a server record missing locally duplicates a local row.
  public enum SyncSurveyDuplicateCheck: Sendable {
    case candidate, notCandidate, missingFields
  }

  public enum SyncSurveyError: Error, Equatable {
    case notRunning
    case identityChanged
  }

  /// Distinct-record counts for one table, category and reason. Every category is a candidate,
  /// not a confirmed dropped write.
  public struct SyncSurveyCount: Hashable, Sendable {
    public var table: String
    public var category: String
    public var reason: String
    public var count: Int
  }

  /// Survey progress, persisted by the caller after every page.
  ///
  /// Holds record names and class labels only, never field values.
  public struct SyncSurveyCheckpoint: Codable, Hashable, Sendable {
    public let identity: SyncSurveyRunIdentity
    public let runID: UUID
    public internal(set) var pages = 0
    public internal(set) var bytes = 0
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var isComplete = false
    var changeToken: Data?
    /// Record name to "category/reason", reclassified on every observation.
    var inventory: [String: String] = [:]
    /// B and C candidates as "table/category/reason" to count, filled in on completion.
    var completionCounts: [String: Int] = [:]

    init(identity: SyncSurveyRunIdentity) {
      self.identity = identity
      self.runID = UUID()
    }

    public var counts: [SyncSurveyCount] {
      var totals = completionCounts
      for (recordName, label) in inventory {
        let table = CKRecord.ID(recordName: recordName).tableName ?? "unknown"
        totals["\(table)/\(label)", default: 0] += 1
      }
      return totals.map { key, count in
        let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
        return SyncSurveyCount(table: parts[0], category: parts[1], reason: parts[2], count: count)
      }
      .sorted { ($0.table, $0.category, $0.reason) < ($1.table, $1.category, $1.reason) }
    }
  }

  public struct SyncSurveyOptions: Sendable {
    public var environment: String
    public var databaseGeneration: @Sendable () async -> Int
    public var maxPages: Int
    public var resultsLimit: Int
    /// Fields the duplicate check reads. System fields are always fetched.
    public var desiredKeys: [CKRecord.FieldKey]
    /// Runs in a read transaction on the user database for records classified A-missing.
    public var duplicateCheck: (@Sendable (CKRecord, Database) throws -> SyncSurveyDuplicateCheck)?

    public init(
      environment: String,
      databaseGeneration: @escaping @Sendable () async -> Int,
      maxPages: Int = 20,
      resultsLimit: Int = 200,
      desiredKeys: [CKRecord.FieldKey] = [],
      duplicateCheck: (@Sendable (CKRecord, Database) throws -> SyncSurveyDuplicateCheck)? = nil
    ) {
      self.environment = environment
      self.databaseGeneration = databaseGeneration
      self.maxPages = maxPages
      self.resultsLimit = resultsLimit
      self.desiredKeys = desiredKeys
      self.duplicateCheck = duplicateCheck
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    public static let syncSurveyVersion = 1

    /// Counts server records in the private default zone that this device may have lost.
    ///
    /// Read-only for user and sync data: it fetches raw zone changes from a nil token and reads
    /// local state, but never writes user rows, sync metadata, pending changes, failures, or
    /// CKSyncEngine state. Its own progress goes to `persist` after each page, once the run
    /// identity has been rechecked. Pass the last persisted checkpoint to resume. Returns early
    /// after `maxPages` pages, and a completed checkpoint for the same identity is returned
    /// unchanged.
    public func surveyServerDiscrepancies(
      resuming previous: SyncSurveyCheckpoint?,
      options: SyncSurveyOptions,
      persist: @Sendable (SyncSurveyCheckpoint) async throws -> Void,
      onRunState: @Sendable (SyncSurveyRunState, SyncSurveyCheckpoint) async -> Void = { _, _ in }
    ) async throws -> SyncSurveyCheckpoint {
      guard isRunning else { throw SyncSurveyError.notRunning }
      let identity = try await surveyIdentity(options)
      var checkpoint: SyncSurveyCheckpoint
      if let previous, previous.identity == identity {
        if previous.isComplete { return previous }
        checkpoint = previous
        await onRunState(.resumed, checkpoint)
      } else {
        checkpoint = SyncSurveyCheckpoint(identity: identity)
        try await persist(checkpoint)
        await onRunState(.started, checkpoint)
      }

      let database: any CloudDatabase = container.privateCloudDatabase
      for _ in 0..<options.maxPages {
        try Task.checkCancellation()
        let start = Date()
        let page: ZoneChangesPage
        do {
          page = try await database.zoneChangesPage(
            in: defaultZone.zoneID,
            since: checkpoint.changeToken,
            desiredKeys: options.desiredKeys,
            resultsLimit: options.resultsLimit
          )
        } catch let error as CKError where error.code == .changeTokenExpired {
          checkpoint = SyncSurveyCheckpoint(identity: identity)
          try await persist(checkpoint)
          await onRunState(.started, checkpoint)
          continue
        }

        var next = checkpoint
        for recordID in page.deletions {
          next.inventory[recordID.recordName] = nil
        }
        let (labels, bytes) = try await surveyClassify(page.modifications, options: options)
        next.inventory.merge(labels) { $1 }
        next.changeToken = page.changeToken
        next.pages += 1
        next.bytes += bytes
        if !page.moreComing {
          next.completionCounts = try await surveyCompletionCounts(seen: next.inventory)
          next.isComplete = true
        }
        next.duration += Date().timeIntervalSince(start)
        guard try await surveyIdentity(options) == identity
        else { throw SyncSurveyError.identityChanged }
        try await persist(next)
        checkpoint = next
        if checkpoint.isComplete {
          await onRunState(.completed, checkpoint)
          break
        }
      }
      return checkpoint
    }

    private func surveyIdentity(_ options: SyncSurveyOptions) async throws -> SyncSurveyRunIdentity {
      SyncSurveyRunIdentity(
        containerIdentifier: container.containerIdentifier ?? "",
        environment: options.environment,
        userRecordName: try await container.userRecordID().recordName,
        zoneName: defaultZone.zoneID.zoneName,
        zoneOwnerName: defaultZone.zoneID.ownerName,
        databaseGeneration: await options.databaseGeneration(),
        surveyVersion: Self.syncSurveyVersion
      )
    }

    /// Record IDs that are protected from classification: pending in CKSyncEngine or SQLite,
    /// durably failed, or unsynced.
    private func surveyProtectedIDs(
      db: Database
    ) throws -> (pending: Set<CKRecord.ID>, failed: Set<CKRecord.ID>, unsynced: Set<CKRecord.ID>) {
      let enginePending = syncEngines.withValue { $0.private?.state.pendingRecordZoneChanges } ?? []
      let sqlitePending = try PendingRecordZoneChange.select(\.pendingRecordZoneChange).fetchAll(db)
      return (
        Set((enginePending + sqlitePending).compactMap(\.id)),
        Set(try DurableRecordZoneFailure.all.fetchAll(db).map(\.recordID)),
        Set(
          try UnsyncedRecordID.all.fetchAll(db).map {
            CKRecord.ID(
              recordName: $0.recordName,
              zoneID: CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName)
            )
          }
        )
      )
    }

    private func surveyClassify(
      _ modifications: [CKRecord.ID: Result<CKRecord, any Error>],
      options: SyncSurveyOptions
    ) async throws -> (labels: [String: String], bytes: Int) {
      guard !modifications.isEmpty else { return ([:], 0) }
      let (metadataByName, protected) = try await metadatabase.read { db in
        let metadata = try SyncMetadata.findAll(modifications.keys).fetchAll(db)
        return (
          Dictionary(metadata.map { ($0.recordName, $0) }, uniquingKeysWith: { $1 }),
          try surveyProtectedIDs(db: db)
        )
      }
      let tablesByName = tablesByName
      return try await userDatabase.read { db in
        var labels: [String: String] = [:]
        var bytes = 0
        for (recordID, result) in modifications {
          guard case .success(let record) = result else {
            labels[recordID.recordName] = "protected/fetch_failed"
            continue
          }
          bytes +=
            (try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true))?
            .count ?? 0
          labels[recordID.recordName] = try surveyLabel(
            record,
            metadata: metadataByName[recordID.recordName],
            protected: protected,
            tablesByName: tablesByName,
            duplicateCheck: options.duplicateCheck,
            db: db
          )
        }
        return (labels, bytes)
      }
    }

    /// Classification precedence from the design: protected/unknown, A-missing, A-stale,
    /// A-other, then tag-current. Returns "category/reason".
    private func surveyLabel(
      _ record: CKRecord,
      metadata: SyncMetadata?,
      protected: (pending: Set<CKRecord.ID>, failed: Set<CKRecord.ID>, unsynced: Set<CKRecord.ID>),
      tablesByName: [String: any SynchronizableTable],
      duplicateCheck: (@Sendable (CKRecord, Database) throws -> SyncSurveyDuplicateCheck)?,
      db: Database
    ) throws -> String {
      let recordID = record.recordID
      guard
        recordID.tableName == record.recordType,
        let rowExists = try surveyRowExists(recordID, tablesByName: tablesByName, db: db)
      else { return "protected/unsupported_record_type" }
      if metadata?._isDeleted == true { return "protected/tombstone" }
      if protected.pending.contains(recordID) { return "protected/pending_change" }
      if protected.failed.contains(recordID) { return "protected/durable_failure" }
      if protected.unsynced.contains(recordID) { return "protected/unsynced_record" }
      guard let metadata else {
        if rowExists { return "a_other/row_without_metadata" }
        switch try duplicateCheck?(record, db) ?? .notCandidate {
        case .missingFields: return "protected/missing_projected_fields"
        case .candidate: return "a_missing/duplicate_candidate"
        case .notCandidate: return "a_missing/no_duplicate"
        }
      }
      guard let baseline = metadata._lastKnownServerRecordAllFields
      else { return "protected/missing_baseline" }
      guard rowExists else { return "a_other/metadata_without_row" }
      let localTag = (metadata.lastKnownServerRecord ?? baseline).surveyChangeTag
      if let localTag, localTag == record.surveyChangeTag { return "tag_current/row_present" }
      guard
        let serverDate = record.surveyModificationDate,
        let baselineDate = baseline.surveyModificationDate,
        serverDate > baselineDate
      else { return "a_other/server_not_newer" }
      return "a_stale/server_newer"
    }

    /// `nil` when the record ID does not name a synchronized table.
    private func surveyRowExists(
      _ recordID: CKRecord.ID,
      tablesByName: [String: any SynchronizableTable],
      db: Database
    ) throws -> Bool? {
      guard
        let tableName = recordID.tableName,
        let table = tablesByName[tableName],
        let primaryKey = recordID.recordPrimaryKey
      else { return nil }
      func open<T>(_: some SynchronizableTable<T>) throws -> Bool {
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (SELECT 1 FROM \(T.tableName.quotedDatabaseIdentifier) \
            WHERE \(T.primaryKey.name.quotedDatabaseIdentifier) = ?)
            """,
          arguments: [primaryKey]
        ) ?? false
      }
      return try open(table)
    }

    /// B candidates (local rows with a baseline never seen on the server during a complete
    /// enumeration) and C candidates (terminal save failures), as "table/category/reason".
    private func surveyCompletionCounts(seen: [String: String]) async throws -> [String: Int] {
      let zoneID = defaultZone.zoneID
      let (baselineNames, failures, protected) = try await metadatabase.read { db in
        let names = try String.fetchAll(
          db,
          sql: """
            SELECT "recordName" FROM "\(String.sqliteDataCloudKitSchemaName)_metadata"
            WHERE "zoneName" = ? AND "ownerName" = ? AND NOT "_isDeleted"
            AND "_lastKnownServerRecordAllFields" IS NOT NULL
            """,
          arguments: [zoneID.zoneName, zoneID.ownerName]
        )
        let failures = try DurableRecordZoneFailure
          .where {
            $0.isTerminal && $0.action.eq(DurableRecordZoneFailure.saveAction)
              && $0.zoneName.eq(zoneID.zoneName) && $0.ownerName.eq(zoneID.ownerName)
          }
          .fetchAll(db)
        return (Set(names), failures, try surveyProtectedIDs(db: db))
      }
      let tablesByName = tablesByName
      return try await userDatabase.read { db in
        var counts: [String: Int] = [:]
        for recordName in baselineNames where seen[recordName] == nil {
          let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
          guard
            !protected.pending.contains(recordID),
            !protected.failed.contains(recordID),
            !protected.unsynced.contains(recordID),
            let tableName = recordID.tableName,
            try surveyRowExists(recordID, tablesByName: tablesByName, db: db) == true
          else { continue }
          counts["\(tableName)/b_candidate/not_seen_on_server", default: 0] += 1
        }
        for failure in failures {
          let recordID = failure.recordID
          let table = failure.recordType ?? recordID.tableName ?? "unknown"
          let row =
            try surveyRowExists(recordID, tablesByName: tablesByName, db: db) == true
            ? "row" : "no_row"
          let baseline = baselineNames.contains(recordID.recordName) ? "baseline" : "no_baseline"
          counts["\(table)/c_candidate/code\(failure.errorCode)_\(row)_\(baseline)", default: 0] += 1
        }
        return counts
      }
    }
  }

  extension CKRecord {
    /// The mock database keeps its tag in `_recordChangeTag`.
    fileprivate var surveyChangeTag: String? {
      recordChangeTag ?? _recordChangeTag.map(String.init)
    }

    /// Tests set `_modificationDate` because mock records have no `modificationDate`.
    fileprivate var surveyModificationDate: Date? {
      modificationDate ?? self["_modificationDate"] as? Date
    }
  }
#endif
