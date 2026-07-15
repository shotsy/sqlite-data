#if canImport(CloudKit)
  package import CloudKit
  import StructuredQueries
  package import StructuredQueriesCore

  @Table("sqlitedata_icloud_durableRecordZoneFailures")
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  package struct DurableRecordZoneFailure: Equatable {
    package let recordName: String
    package let zoneName: String
    package let ownerName: String
    package let action: String
    package var recordType: String?
    package var errorCode: Int
    package var attemptCount: Int
    package var isTerminal: Bool
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension DurableRecordZoneFailure {
    package static let saveAction = "save"
    package static let deleteAction = "delete"

    package init(
      recordID: CKRecord.ID,
      action: String,
      recordType: String?,
      errorCode: CKError.Code,
      attemptCount: Int,
      isTerminal: Bool
    ) {
      self.recordName = recordID.recordName
      self.zoneName = recordID.zoneID.zoneName
      self.ownerName = recordID.zoneID.ownerName
      self.action = action
      self.recordType = recordType
      self.errorCode = errorCode.rawValue
      self.attemptCount = attemptCount
      self.isTerminal = isTerminal
    }

    package var recordID: CKRecord.ID {
      CKRecord.ID(
        recordName: recordName,
        zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
      )
    }

    package static func find(
      _ recordID: CKRecord.ID,
      action: String
    ) -> Where<DurableRecordZoneFailure> {
      Self.where {
        $0.recordName.eq(recordID.recordName)
          && $0.zoneName.eq(recordID.zoneID.zoneName)
          && $0.ownerName.eq(recordID.zoneID.ownerName)
          && $0.action.eq(action)
      }
    }

    package static func findAll(
      _ recordIDs: some Collection<CKRecord.ID>,
      action: String
    ) -> Where<DurableRecordZoneFailure> {
      let condition: QueryFragment = recordIDs.map {
        "(\(bind: $0.recordName), \(bind: $0.zoneID.zoneName), \(bind: $0.zoneID.ownerName))"
      }
      .joined(separator: ", ")
      return Self.where {
        $0.action.eq(action)
          && #sql("(\($0.recordName), \($0.zoneName), \($0.ownerName)) IN (\(condition))")
      }
    }
  }
#endif
