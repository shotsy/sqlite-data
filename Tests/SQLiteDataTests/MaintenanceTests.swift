import Foundation
import SQLiteData
import Testing

struct MaintenanceTests {
  private struct Failure: Error {}

  @Test func standaloneNestedAndThrowingScopes() throws {
    let database = try DatabaseQueue()
    try database.writeWithoutTransaction { db in
      // A failed first scope rolls back installation as well as the operation.
      #expect(throws: Failure.self) {
        try SQLiteDataMaintenance.withScope(in: db) { throw Failure() }
      }
      #expect(try !db.tableExists("sqlitedata_maintenanceContext"))
      try SQLiteDataMaintenance.install(in: db)
      try SQLiteDataMaintenance.install(in: db)
      try db.execute(sql: "CREATE TABLE effects (value INTEGER)")
      let value: Int? = try SQLiteDataMaintenance.withScope(in: db) {
        #expect(try isActive(db))
        try db.execute(sql: "INSERT INTO effects VALUES (1)")
        try SQLiteDataMaintenance.withScope(in: db) { () throws in
          #expect(try isActive(db))
        }
        #expect(try isActive(db))
        #expect(throws: Failure.self) {
          try SQLiteDataMaintenance.withScope(in: db) {
            try db.execute(sql: "INSERT INTO effects VALUES (2)")
            throw Failure()
          }
        }
        #expect(try isActive(db))
        return nil
      }
      #expect(value == nil)
      #expect(try !isActive(db))
      #expect(try Int.fetchAll(db, sql: "SELECT value FROM effects") == [1])
      #expect(throws: Failure.self) {
        try SQLiteDataMaintenance.withScope(in: db) {
          try db.execute(sql: "INSERT INTO effects VALUES (3)")
          throw Failure()
        }
      }
      #expect(try !isActive(db))
      #expect(try Int.fetchAll(db, sql: "SELECT value FROM effects") == [1])
      try db.inTransaction { () throws in
        #expect(try SQLiteDataMaintenance.withScope(in: db) {
          try db.execute(sql: "INSERT INTO effects VALUES (4)")
          return 42
        } == 42)
        return .rollback
      }
      #expect(try !isActive(db))
      #expect(try Int.fetchAll(db, sql: "SELECT value FROM effects") == [1])
      // An already-active marker is not owned (or cleared) by the inner scope.
      try db.execute(sql: "INSERT INTO sqlitedata_maintenanceContext VALUES (1)")
      try SQLiteDataMaintenance.withScope(in: db) {}
      #expect(try isActive(db))
      #expect(throws: DatabaseError.self) {
        try db.execute(sql: "INSERT INTO sqlitedata_maintenanceContext VALUES (2)")
      }
      #expect(throws: DatabaseError.self) {
        try db.execute(sql: "INSERT INTO sqlitedata_maintenanceContext VALUES (1)")
      }
    }
  }

  @Test func lazyScopeDoesNotChangePersistentSchema() throws {
    let database = try DatabaseQueue()
    try database.writeWithoutTransaction { db in
      try SQLiteDataMaintenance.withScope(in: db) {
        #expect(try isActive(db))
        try SQLiteDataMaintenance.withScope(in: db) { () throws in
          #expect(try isActive(db))
        }
      }
      #expect(try !db.tableExists("sqlitedata_maintenanceContext"))
    }
  }

  @Test func permanentTriggerWithoutSyncEngineAndReopen() throws {
    let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    do {
      let database = try DatabaseQueue(path: path)
      try database.write { db in
        try SQLiteDataMaintenance.install(in: db)
        try db.execute(sql: """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE audit (maintenance INTEGER);
          CREATE TRIGGER audit_delete AFTER DELETE ON items BEGIN
            INSERT INTO audit VALUES (\(SQLiteDataMaintenance.isActiveSQL));
          END;
          INSERT INTO items VALUES (1), (2);
          """)
      }
    }
    let reopened = try DatabaseQueue(path: path)
    try reopened.write { db in
      try SQLiteDataMaintenance.withScope(in: db) {
        try db.execute(sql: "DELETE FROM items WHERE id = 1")
      }
      try db.execute(sql: "DELETE FROM items WHERE id = 2")
      #expect(try Int.fetchAll(db, sql: "SELECT maintenance FROM audit") == [1, 0])
      #expect(try !isActive(db))
    }
  }
}

private func isActive(_ db: Database) throws -> Bool {
  try Bool.fetchOne(db, sql: "SELECT \(SQLiteDataMaintenance.isActiveSQL)") == true
}
