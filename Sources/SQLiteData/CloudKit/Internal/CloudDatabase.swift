#if canImport(CloudKit)
  public import CloudKit

  package protocol CloudDatabase: AnyObject, Hashable, Sendable {
    var databaseScope: CKDatabase.Scope { get }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func records(
      for ids: [CKRecord.ID],
      desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func modifyRecords(
      saving recordsToSave: [CKRecord],
      deleting recordIDsToDelete: [CKRecord.ID],
      savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
      atomically: Bool
    ) async throws -> (
      saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
      deleteResults: [CKRecord.ID: Result<Void, any Error>]
    )

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func modifyRecordZones(
      saving recordZonesToSave: [CKRecordZone],
      deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
      saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
      deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    )

    /// One page of raw zone changes. The token is an archived `CKServerChangeToken` so it can
    /// be persisted; `nil` starts from the beginning of the zone.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func zoneChangesPage(
      in zoneID: CKRecordZone.ID,
      since changeToken: Data?,
      desiredKeys: [CKRecord.FieldKey]?,
      resultsLimit: Int
    ) async throws -> ZoneChangesPage
  }

  package struct ZoneChangesPage: Sendable {
    package var modifications: [CKRecord.ID: Result<CKRecord, any Error>]
    package var deletions: [CKRecord.ID]
    package var changeToken: Data
    package var moreComing: Bool
  }

  extension CKDatabase {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    package func zoneChangesPage(
      in zoneID: CKRecordZone.ID,
      since changeToken: Data?,
      desiredKeys: [CKRecord.FieldKey]?,
      resultsLimit: Int
    ) async throws -> ZoneChangesPage {
      let token = try changeToken.flatMap {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
      }
      let changes = try await recordZoneChanges(
        inZoneWith: zoneID,
        since: token,
        desiredKeys: desiredKeys,
        resultsLimit: resultsLimit
      )
      return ZoneChangesPage(
        modifications: changes.modificationResultsByID.mapValues { $0.map(\.record) },
        deletions: changes.deletions.map(\.recordID),
        changeToken: try NSKeyedArchiver.archivedData(
          withRootObject: changes.changeToken,
          requiringSecureCoding: true
        ),
        moreComing: changes.moreComing
      )
    }
  }

  extension CloudDatabase {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func modifyRecords(
      saving recordsToSave: [CKRecord],
      deleting recordIDsToDelete: [CKRecord.ID]
    ) async throws -> (
      saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
      deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
      try await modifyRecords(
        saving: recordsToSave,
        deleting: recordIDsToDelete,
        savePolicy: .ifServerRecordUnchanged,
        atomically: true
      )
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    package func records(
      for ids: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
      try await records(for: ids, desiredKeys: nil)
    }
  }

  extension CKDatabase: CloudDatabase {}

  final class AnyCloudDatabase: CloudDatabase {
    let rawValue: any CloudDatabase
    init(_ rawValue: any CloudDatabase) {
      self.rawValue = rawValue
    }

    var databaseScope: CKDatabase.Scope {
      rawValue.databaseScope
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
      try await rawValue.record(for: recordID)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func records(
      for ids: [CKRecord.ID],
      desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
      try await rawValue.records(for: ids)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func modifyRecords(
      saving recordsToSave: [CKRecord],
      deleting recordIDsToDelete: [CKRecord.ID],
      savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
      atomically: Bool
    ) async throws -> (
      saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
      deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
      try await rawValue.modifyRecords(
        saving: recordsToSave,
        deleting: recordIDsToDelete,
        savePolicy: savePolicy,
        atomically: atomically
      )
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func modifyRecordZones(
      saving recordZonesToSave: [CKRecordZone],
      deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
      saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
      deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
      try await rawValue.modifyRecordZones(
        saving: recordZonesToSave, deleting: recordZoneIDsToDelete)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func zoneChangesPage(
      in zoneID: CKRecordZone.ID,
      since changeToken: Data?,
      desiredKeys: [CKRecord.FieldKey]?,
      resultsLimit: Int
    ) async throws -> ZoneChangesPage {
      try await rawValue.zoneChangesPage(
        in: zoneID, since: changeToken, desiredKeys: desiredKeys, resultsLimit: resultsLimit)
    }

    static func == (lhs: AnyCloudDatabase, rhs: AnyCloudDatabase) -> Bool {
      lhs.rawValue === rhs.rawValue
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(rawValue))
    }
  }
#endif
