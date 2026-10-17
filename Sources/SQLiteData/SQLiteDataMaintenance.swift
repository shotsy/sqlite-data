public import GRDB

/// A SQL-visible maintenance scope shared by app triggers and synchronization metadata.
public enum SQLiteDataMaintenance {
  /// A SQL predicate usable in permanent app triggers, even without a sync engine.
  /// Install the context table before creating triggers that reference it.
  public static let isActiveSQL = "EXISTS(SELECT 1 FROM sqlitedata_maintenanceContext)"

  /// Installs the singleton context table in the app's main database, if needed.
  /// Call from an app migration so schema-replay checks include this persistent table.
  public static func install(in db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS main.sqlitedata_maintenanceContext (
        id INTEGER PRIMARY KEY CHECK (id = 1)
      )
      """)
  }

  /// Runs an operation atomically with maintenance active. Nested scopes preserve their
  /// owner's marker; errors roll back both the operation and any marker changes.
  /// If not installed by a migration, the context table exists only for the scope's duration.
  /// All scoped writes must use this database connection. The operation must not commit or
  /// roll back its enclosing transaction. Direct writes to the reserved context table are unsupported.
  public static func withScope<T>(
    in db: Database,
    _ operation: () throws -> T
  ) throws -> T {
    var result: T?
    try db.inSavepoint {
      let ownsTable = try !isInstalled(in: db)
      try install(in: db)
      let ownsScope = try Bool.fetchOne(db, sql: "SELECT \(isActiveSQL)") != true
      if ownsScope {
        try db.execute(sql: "INSERT INTO main.sqlitedata_maintenanceContext (id) VALUES (1)")
      }
      result = try operation()
      if ownsScope {
        try db.execute(sql: "DELETE FROM main.sqlitedata_maintenanceContext WHERE id = 1")
      }
      if ownsTable {
        try db.execute(sql: "DROP TABLE main.sqlitedata_maintenanceContext")
      }
      return .commit
    }
    return result!
  }

  // Only SyncEngine's temporary triggers need the absent-table-safe predicate. App permanent
  // triggers use isActiveSQL directly against the same marker installed by their migration.
  static func registerPredicate(in db: Database) {
    let connection = Connection(db)
    db.add(function: DatabaseFunction("sqlitedata_maintenanceIsActive", argumentCount: 0) { _ in
      guard let db = connection.db,
        try isInstalled(in: db)
      else { return false }
      return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM main.sqlitedata_maintenanceContext)")
    })
  }

  private static func isInstalled(in db: Database) throws -> Bool {
    try Bool.fetchOne(db, sql: """
      SELECT EXISTS(SELECT 1 FROM main.sqlite_master
        WHERE type = 'table' AND name = 'sqlitedata_maintenanceContext')
      """) == true
  }

  // SQLite invokes this function synchronously on the connection's own serialized queue.
  private final class Connection: @unchecked Sendable {
    weak var db: Database?
    init(_ db: Database) { self.db = db }
  }
}
