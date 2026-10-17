public import GRDB

/// A SQL-visible maintenance scope shared by app triggers and synchronization metadata.
public enum SQLiteDataMaintenance {
  /// A SQL predicate usable in permanent app triggers, even without a sync engine.
  /// Install the context table before creating triggers that reference it.
  public static let isActiveSQL = "EXISTS(SELECT 1 FROM sqlitedata_maintenanceContext)"

  /// Installs the singleton context table in the app's main database, if needed.
  public static func install(in db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS main.sqlitedata_maintenanceContext (
        id INTEGER PRIMARY KEY CHECK (id = 1)
      )
      """)
  }

  /// Runs an operation atomically with maintenance active. Nested scopes preserve their
  /// owner's marker; errors roll back both the operation and any marker changes.
  /// All scoped writes must use this database connection. The operation must not commit or
  /// roll back its enclosing transaction. Direct writes to the reserved context table are unsupported.
  public static func withScope<T>(
    in db: Database,
    _ operation: () throws -> T
  ) throws -> T {
    var result: T?
    try db.inSavepoint {
      try install(in: db)
      let ownsScope = try Bool.fetchOne(db, sql: "SELECT \(isActiveSQL)") != true
      if ownsScope {
        try db.execute(sql: "INSERT INTO main.sqlitedata_maintenanceContext (id) VALUES (1)")
      }
      result = try operation()
      if ownsScope {
        try db.execute(sql: "DELETE FROM main.sqlitedata_maintenanceContext WHERE id = 1")
      }
      return .commit
    }
    return result!
  }
}
