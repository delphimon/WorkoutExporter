import ActivityArchiveCore
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    sqlite3_close_v2(pointer)
  }
}

public actor ActivityVaultDatabase {
  public let layout: ActivityVaultLayout
  private let connection: SQLiteConnection

  public init(layout: ActivityVaultLayout) throws {
    self.layout = layout
    try layout.validate()
    if !FileManager.default.fileExists(atPath: layout.database.path) {
      guard
        FileManager.default.createFile(
          atPath: layout.database.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw ActivityVaultError.database("Could not create the SQLite catalog")
      }
    }
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      layout.database.path,
      &database,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let database else {
      let message =
        database.map { String(cString: sqlite3_errmsg($0)) }
        ?? "Could not open SQLite catalog"
      if let database { sqlite3_close_v2(database) }
      throw ActivityVaultError.database(message)
    }
    do {
      try Self.configure(database)
      try Self.migrate(database)
      try Self.secureDatabaseFiles(layout: layout)
    } catch {
      sqlite3_close_v2(database)
      throw error
    }
    connection = SQLiteConnection(database)
  }

  public func startImport(
    id: UUID,
    filename: String,
    sourcePath: String?,
    kind: ActivityImportKind,
    startedAt: Date = Date()
  ) throws {
    try execute(
      """
      INSERT INTO import_jobs(
        id, source_filename, source_path, kind, status, started_at
      ) VALUES(?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(id.uuidString.lowercased()),
        .text(filename),
        sourcePath.map(SQLiteValue.text) ?? .null,
        .text(kind.rawValue),
        .text(ActivityImportStatus.importing.rawValue),
        .double(startedAt.timeIntervalSince1970),
      ]
    )
  }

  func recordArtifact(
    object: ActivityStoredObject,
    kind: ActivityImportKind,
    originalFilename: String,
    importedAt: Date = Date()
  ) throws {
    try transaction {
      try execute(
        "INSERT OR IGNORE INTO objects(hash, byte_length, created_at) VALUES(?, ?, ?)",
        bindings: [
          .text(object.sha256),
          .int64(try sqliteInteger(object.byteLength, field: "object byte length")),
          .double(importedAt.timeIntervalSince1970),
        ]
      )
      try execute(
        """
        INSERT INTO imported_artifacts(
          object_hash, kind, original_filename, imported_at, import_count
        ) VALUES(?, ?, ?, ?, 1)
        ON CONFLICT(object_hash) DO UPDATE SET
          import_count = import_count + 1,
          imported_at = excluded.imported_at
        """,
        bindings: [
          .text(object.sha256),
          .text(kind.rawValue),
          .text(originalFilename),
          .double(importedAt.timeIntervalSince1970),
        ]
      )
    }
  }

  func commitImport(
    jobID: UUID,
    object: ActivityStoredObject,
    draft: ImportedObservationDraft,
    importedAt: Date = Date()
  ) throws -> (ActivityImportStatus, Int64) {
    guard draft.packageRevision <= UInt64(Int64.max) else {
      throw ActivityVaultError.invalidArtifact("Package revision exceeds SQLite range")
    }
    return try transaction {
      if let existing = try existingObservation(
        packageID: draft.packageID,
        revision: draft.packageRevision
      ) {
        guard existing.contentHash == draft.contentHash else {
          throw ActivityVaultError.revisionConflict(
            packageID: draft.packageID,
            revision: draft.packageRevision
          )
        }
        try finishJob(
          id: jobID,
          status: .duplicate,
          contentHash: object.sha256,
          message: nil,
          completedAt: importedAt
        )
        return (ActivityImportStatus.duplicate, existing.id)
      }

      try execute(
        """
        INSERT INTO source_observations(
          package_id, package_revision, source_activity_id, content_hash,
          object_hash, kind, workout_type_identifier, workout_type_name,
          title, start_date, end_date, time_zone_identifier, duration_seconds,
          source_name, source_bundle_identifier, completeness, route_state, metrics_state,
          metadata_json, imported_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(draft.packageID.uuidString.lowercased()),
          .int64(Int64(draft.packageRevision)),
          .text(draft.sourceActivityID),
          .text(draft.contentHash),
          .text(object.sha256),
          .text(draft.kind.rawValue),
          try draft.workoutTypeIdentifier.map {
            .int64(try sqliteInteger(UInt64($0), field: "workout type identifier"))
          } ?? .null,
          .text(draft.workoutTypeName),
          draft.title.map(SQLiteValue.text) ?? .null,
          draft.startDate.map { .double($0.timeIntervalSince1970) } ?? .null,
          draft.endDate.map { .double($0.timeIntervalSince1970) } ?? .null,
          draft.timeZoneIdentifier.map(SQLiteValue.text) ?? .null,
          draft.durationSeconds.map(SQLiteValue.double) ?? .null,
          .text(draft.sourceName),
          draft.sourceBundleIdentifier.map(SQLiteValue.text) ?? .null,
          .text(draft.completeness),
          .text(draft.routeState),
          .text(draft.metricsState),
          .blob(draft.metadataJSON),
          .double(importedAt.timeIntervalSince1970),
        ]
      )
      let observationID = sqlite3_last_insert_rowid(connection.pointer)

      for statistic in draft.sourceStatistics {
        try execute(
          """
          INSERT INTO source_statistics(
            observation_id, identifier, aggregation, value, unit, provenance
          ) VALUES(?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .int64(observationID), .text(statistic.identifier),
            .text(statistic.aggregation), .double(statistic.value),
            .text(statistic.unit), .text(statistic.provenance),
          ]
        )
      }
      for route in draft.routes {
        try execute(
          """
          INSERT INTO source_routes(
            observation_id, track_id, point_count, minimum_latitude,
            maximum_latitude, minimum_longitude, maximum_longitude,
            has_timestamps
          ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .int64(observationID), .text(route.trackID),
            .int64(try sqliteInteger(route.pointCount, field: "route point count")),
            route.minimumLatitude.map(SQLiteValue.double) ?? .null,
            route.maximumLatitude.map(SQLiteValue.double) ?? .null,
            route.minimumLongitude.map(SQLiteValue.double) ?? .null,
            route.maximumLongitude.map(SQLiteValue.double) ?? .null,
            .int64(route.hasTimestamps ? 1 : 0),
          ]
        )
        let routeID = sqlite3_last_insert_rowid(connection.pointer)
        if let minLat = route.minimumLatitude, let maxLat = route.maximumLatitude,
          let minLon = route.minimumLongitude, let maxLon = route.maximumLongitude
        {
          try execute(
            "INSERT INTO source_route_bounds(id, min_lat, max_lat, min_lon, max_lon) VALUES(?, ?, ?, ?, ?)",
            bindings: [
              .int64(routeID), .double(minLat), .double(maxLat),
              .double(minLon), .double(maxLon),
            ]
          )
        }
      }
      for warning in draft.warnings {
        try execute(
          "INSERT INTO import_warnings(job_id, code, message) VALUES(?, ?, ?)",
          bindings: [
            .text(jobID.uuidString.lowercased()), .text("source-warning"),
            .text(warning),
          ]
        )
      }
      try finishJob(
        id: jobID,
        status: .imported,
        contentHash: object.sha256,
        message: nil,
        completedAt: importedAt
      )
      return (.imported, observationID)
    }
  }

  public func rejectImport(
    id: UUID,
    contentHash: String?,
    message: String,
    completedAt: Date = Date()
  ) throws {
    try finishJob(
      id: id,
      status: .rejected,
      contentHash: contentHash,
      message: message,
      completedAt: completedAt
    )
  }

  public func cancelImport(id: UUID, completedAt: Date = Date()) throws {
    try finishJob(
      id: id,
      status: .cancelled,
      contentHash: nil,
      message: "Import cancelled",
      completedAt: completedAt
    )
  }

  func recordWarning(jobID: UUID, code: String, message: String) throws {
    try execute(
      "INSERT INTO import_warnings(job_id, code, message) VALUES(?, ?, ?)",
      bindings: [
        .text(jobID.uuidString.lowercased()), .text(code), .text(message),
      ]
    )
  }

  public func importJobs(limit: Int = 100) throws -> [ActivityImportJob] {
    let rows = try query(
      """
      SELECT id, source_filename, source_path, kind, content_hash, status,
             started_at, completed_at, error_message
      FROM import_jobs ORDER BY started_at DESC LIMIT ?
      """,
      bindings: [.int64(Int64(max(1, min(limit, 10_000))))]
    )
    return try rows.map { row in
      guard let id = UUID(uuidString: try row.text(0)),
        let kind = ActivityImportKind(rawValue: try row.text(3)),
        let status = ActivityImportStatus(rawValue: try row.text(5))
      else {
        throw ActivityVaultError.database("An import job contains invalid identifiers")
      }
      return ActivityImportJob(
        id: id,
        sourceFilename: try row.text(1),
        sourcePath: row.optionalText(2),
        kind: kind,
        contentHash: row.optionalText(4),
        status: status,
        startedAt: Date(timeIntervalSince1970: try row.double(6)),
        completedAt: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)),
        errorMessage: row.optionalText(8)
      )
    }
  }

  public func observations(limit: Int = 1_000) throws -> [ActivitySourceObservation] {
    let rows = try query(
      """
      SELECT id, package_id, package_revision, source_activity_id, content_hash,
             object_hash, kind, workout_type_identifier, workout_type_name,
             title, start_date, end_date, time_zone_identifier, duration_seconds,
             source_name, source_bundle_identifier, completeness, route_state, metrics_state,
             imported_at
      FROM source_observations
      ORDER BY COALESCE(start_date, imported_at) DESC LIMIT ?
      """,
      bindings: [.int64(Int64(max(1, min(limit, 100_000))))]
    )
    return try rows.map { row in
      guard let packageID = UUID(uuidString: try row.text(1)),
        let kind = ActivityImportKind(rawValue: try row.text(6))
      else {
        throw ActivityVaultError.database("A source observation contains invalid identifiers")
      }
      return ActivitySourceObservation(
        id: try row.int64(0),
        packageID: packageID,
        packageRevision: try unsigned64(try row.int64(2), field: "package revision"),
        sourceActivityID: try row.text(3),
        contentHash: try row.text(4),
        objectHash: try row.text(5),
        kind: kind,
        workoutTypeIdentifier: try optionalUInt(
          row.optionalInt64(7),
          field: "workout type identifier"
        ),
        workoutTypeName: try row.text(8),
        title: row.optionalText(9),
        startDate: row.optionalDouble(10).map(Date.init(timeIntervalSince1970:)),
        endDate: row.optionalDouble(11).map(Date.init(timeIntervalSince1970:)),
        timeZoneIdentifier: row.optionalText(12),
        durationSeconds: row.optionalDouble(13),
        sourceName: try row.text(14),
        sourceBundleIdentifier: row.optionalText(15),
        completeness: try row.text(16),
        routeState: try row.text(17),
        metricsState: try row.text(18),
        importedAt: Date(timeIntervalSince1970: try row.double(19))
      )
    }
  }

  public func sourceStatistics(observationID: Int64) throws -> [ActivityPackageStatistic] {
    try query(
      """
      SELECT identifier, aggregation, value, unit, provenance
      FROM source_statistics WHERE observation_id = ? ORDER BY id
      """,
      bindings: [.int64(observationID)]
    ).map { row in
      ActivityPackageStatistic(
        identifier: try row.text(0),
        aggregation: try row.text(1),
        value: try row.double(2),
        unit: try row.text(3),
        provenance: try row.text(4)
      )
    }
  }

  public func routeSummaries(observationID: Int64) throws -> [ActivitySourceRouteSummary] {
    try query(
      """
      SELECT id, observation_id, track_id, point_count, minimum_latitude,
             maximum_latitude, minimum_longitude, maximum_longitude, has_timestamps
      FROM source_routes WHERE observation_id = ? ORDER BY id
      """,
      bindings: [.int64(observationID)]
    ).map { row in
      ActivitySourceRouteSummary(
        id: try row.int64(0),
        observationID: try row.int64(1),
        trackID: try row.text(2),
        pointCount: try unsigned64(try row.int64(3), field: "route point count"),
        minimumLatitude: row.optionalDouble(4),
        maximumLatitude: row.optionalDouble(5),
        minimumLongitude: row.optionalDouble(6),
        maximumLongitude: row.optionalDouble(7),
        hasTimestamps: try row.int64(8) == 1
      )
    }
  }

  public func warnings(jobID: UUID) throws -> [ActivityImportWarning] {
    try query(
      "SELECT id, code, message FROM import_warnings WHERE job_id = ? ORDER BY id",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).map { row in
      ActivityImportWarning(
        id: try row.int64(0),
        jobID: jobID,
        code: try row.text(1),
        message: try row.text(2)
      )
    }
  }

  public func objectHashes() throws -> [String] {
    try query("SELECT hash FROM objects ORDER BY hash").map { try $0.text(0) }
  }

  func objectRecords() throws -> [(hash: String, byteLength: UInt64)] {
    try query("SELECT hash, byte_length FROM objects ORDER BY hash").map { row in
      (
        hash: try row.text(0),
        byteLength: try unsigned64(try row.int64(1), field: "object byte length")
      )
    }
  }

  public func integrityCheck() throws -> [String] {
    try query("PRAGMA integrity_check").map { try $0.text(0) }
  }

  public func recoverInterruptedImports(at date: Date = Date()) throws -> Int {
    try execute(
      """
      UPDATE import_jobs SET status = ?, completed_at = ?,
        error_message = ? WHERE status = ?
      """,
      bindings: [
        .text(ActivityImportStatus.rejected.rawValue),
        .double(date.timeIntervalSince1970),
        .text("Import was interrupted before its catalog transaction completed"),
        .text(ActivityImportStatus.importing.rawValue),
      ]
    )
    return Int(sqlite3_changes(connection.pointer))
  }

  private func existingObservation(
    packageID: UUID,
    revision: UInt64
  ) throws -> (id: Int64, contentHash: String)? {
    let rows = try query(
      "SELECT id, content_hash FROM source_observations WHERE package_id = ? AND package_revision = ?",
      bindings: [
        .text(packageID.uuidString.lowercased()), .int64(Int64(revision)),
      ]
    )
    guard let row = rows.first else { return nil }
    return (try row.int64(0), try row.text(1))
  }

  private func finishJob(
    id: UUID,
    status: ActivityImportStatus,
    contentHash: String?,
    message: String?,
    completedAt: Date
  ) throws {
    try execute(
      """
      UPDATE import_jobs SET status = ?, content_hash = COALESCE(?, content_hash),
        completed_at = ?, error_message = ? WHERE id = ?
      """,
      bindings: [
        .text(status.rawValue), contentHash.map(SQLiteValue.text) ?? .null,
        .double(completedAt.timeIntervalSince1970),
        message.map(SQLiteValue.text) ?? .null,
        .text(id.uuidString.lowercased()),
      ]
    )
  }

  private func transaction<T>(_ work: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try work()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private static func configure(_ database: OpaquePointer) throws {
    guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
      throw ActivityVaultError.database("Could not configure the SQLite busy timeout")
    }
    try execute(database, sql: "PRAGMA foreign_keys = ON")
    try execute(database, sql: "PRAGMA journal_mode = WAL")
    try execute(database, sql: "PRAGMA synchronous = FULL")
    try execute(database, sql: "PRAGMA secure_delete = FAST")
    try execute(database, sql: "PRAGMA trusted_schema = OFF")
  }

  private static func migrate(_ database: OpaquePointer) throws {
    let version = Int(schemaVersion(database))
    guard version <= ActivityVaultSchema.currentVersion else {
      throw ActivityVaultError.database(
        "Catalog schema \(version) is newer than supported schema \(ActivityVaultSchema.currentVersion)"
      )
    }
    guard version < 1 else { return }
    try execute(database, sql: "BEGIN IMMEDIATE")
    do {
      try execute(
        database,
        sql: """
          CREATE TABLE objects(
            hash TEXT PRIMARY KEY CHECK(length(hash) = 64),
            byte_length INTEGER NOT NULL CHECK(byte_length >= 0),
            created_at REAL NOT NULL
          );
          CREATE TABLE imported_artifacts(
            object_hash TEXT PRIMARY KEY REFERENCES objects(hash),
            kind TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            imported_at REAL NOT NULL,
            import_count INTEGER NOT NULL DEFAULT 1 CHECK(import_count > 0)
          );
          CREATE TABLE import_jobs(
            id TEXT PRIMARY KEY,
            source_filename TEXT NOT NULL,
            source_path TEXT,
            kind TEXT NOT NULL,
            content_hash TEXT,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            completed_at REAL,
            error_message TEXT
          );
          CREATE INDEX import_jobs_status_date ON import_jobs(status, started_at DESC);
          CREATE TABLE source_observations(
            id INTEGER PRIMARY KEY,
            package_id TEXT NOT NULL,
            package_revision INTEGER NOT NULL CHECK(package_revision >= 0),
            source_activity_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            object_hash TEXT NOT NULL REFERENCES objects(hash),
            kind TEXT NOT NULL,
            workout_type_identifier INTEGER,
            workout_type_name TEXT NOT NULL,
            title TEXT,
            start_date REAL,
            end_date REAL,
            time_zone_identifier TEXT,
            duration_seconds REAL,
            source_name TEXT NOT NULL,
            source_bundle_identifier TEXT,
            completeness TEXT NOT NULL,
            route_state TEXT NOT NULL,
            metrics_state TEXT NOT NULL,
            metadata_json BLOB NOT NULL,
            imported_at REAL NOT NULL,
            UNIQUE(package_id, package_revision)
          );
          CREATE INDEX source_observations_source_id ON source_observations(source_activity_id);
          CREATE INDEX source_observations_dates ON source_observations(start_date, end_date);
          CREATE TABLE source_statistics(
            id INTEGER PRIMARY KEY,
            observation_id INTEGER NOT NULL REFERENCES source_observations(id) ON DELETE CASCADE,
            identifier TEXT NOT NULL,
            aggregation TEXT NOT NULL,
            value REAL NOT NULL,
            unit TEXT NOT NULL,
            provenance TEXT NOT NULL
          );
          CREATE TABLE source_routes(
            id INTEGER PRIMARY KEY,
            observation_id INTEGER NOT NULL REFERENCES source_observations(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL,
            point_count INTEGER NOT NULL CHECK(point_count >= 0),
            minimum_latitude REAL,
            maximum_latitude REAL,
            minimum_longitude REAL,
            maximum_longitude REAL,
            has_timestamps INTEGER NOT NULL CHECK(has_timestamps IN (0, 1))
          );
          CREATE VIRTUAL TABLE source_route_bounds USING rtree(
            id, min_lat, max_lat, min_lon, max_lon
          );
          CREATE TABLE import_warnings(
            id INTEGER PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES import_jobs(id) ON DELETE CASCADE,
            code TEXT NOT NULL,
            message TEXT NOT NULL
          );
          PRAGMA user_version = 1;
          """
      )
      try execute(database, sql: "COMMIT")
    } catch {
      try? execute(database, sql: "ROLLBACK")
      throw error
    }
  }

  private static func secureDatabaseFiles(layout: ActivityVaultLayout) throws {
    let manager = FileManager.default
    for url in [
      layout.database,
      URL(fileURLWithPath: layout.database.path + "-wal"),
      URL(fileURLWithPath: layout.database.path + "-shm"),
    ] where manager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true else {
        throw ActivityVaultError.unexpectedSymbolicLink(url.path)
      }
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  private static func schemaVersion(_ database: OpaquePointer) -> Int32 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int(statement, 0)
  }

  private static func execute(_ database: OpaquePointer, sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    guard result == SQLITE_OK else {
      let message =
        error.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(error)
      throw ActivityVaultError.database(message)
    }
  }

  private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
    let statement = try prepare(sql, bindings: bindings)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw ActivityVaultError.database(String(cString: sqlite3_errmsg(connection.pointer)))
    }
  }

  private func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
    let statement = try prepare(sql, bindings: bindings)
    defer { sqlite3_finalize(statement) }
    var rows: [SQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else {
        throw ActivityVaultError.database(String(cString: sqlite3_errmsg(connection.pointer)))
      }
      rows.append(SQLiteRow(statement: statement))
    }
  }

  private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw ActivityVaultError.database(String(cString: sqlite3_errmsg(connection.pointer)))
    }
    do {
      for (offset, value) in bindings.enumerated() {
        try value.bind(to: statement, at: Int32(offset + 1))
      }
      return statement
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }

  private func sqliteInteger(_ value: UInt64, field: String) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
      throw ActivityVaultError.invalidArtifact("\(field) exceeds SQLite range")
    }
    return Int64(value)
  }

  private func optionalUInt(_ value: Int64?, field: String) throws -> UInt? {
    guard let value else { return nil }
    guard value >= 0, UInt64(value) <= UInt64(UInt.max) else {
      throw ActivityVaultError.database("\(field) is outside the supported range")
    }
    return UInt(value)
  }

  private func unsigned64(_ value: Int64, field: String) throws -> UInt64 {
    guard value >= 0 else {
      throw ActivityVaultError.database("\(field) is outside the supported range")
    }
    return UInt64(value)
  }
}

private enum SQLiteValue {
  case null
  case int64(Int64)
  case double(Double)
  case text(String)
  case blob(Data)

  func bind(to statement: OpaquePointer, at index: Int32) throws {
    let result: Int32
    switch self {
    case .null:
      result = sqlite3_bind_null(statement, index)
    case .int64(let value):
      result = sqlite3_bind_int64(statement, index, value)
    case .double(let value):
      result = sqlite3_bind_double(statement, index, value)
    case .text(let value):
      result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    case .blob(let data):
      result = data.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
      }
    }
    guard result == SQLITE_OK else {
      throw ActivityVaultError.database("Could not bind SQLite value")
    }
  }
}

private struct SQLiteRow {
  private var values: [SQLiteColumn]

  init(statement: OpaquePointer) {
    values = (0..<sqlite3_column_count(statement)).map { index in
      switch sqlite3_column_type(statement, index) {
      case SQLITE_INTEGER: .int64(sqlite3_column_int64(statement, index))
      case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
      case SQLITE_TEXT:
        .text(String(cString: sqlite3_column_text(statement, index)))
      case SQLITE_BLOB:
        .blob(Self.blob(statement: statement, index: index))
      default: .null
      }
    }
  }

  private static func blob(statement: OpaquePointer, index: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  func int64(_ index: Int) throws -> Int64 {
    guard case .int64(let value) = values[index] else {
      throw ActivityVaultError.database("Expected SQLite integer column \(index)")
    }
    return value
  }

  func optionalInt64(_ index: Int) -> Int64? {
    guard case .int64(let value) = values[index] else { return nil }
    return value
  }

  func double(_ index: Int) throws -> Double {
    switch values[index] {
    case .double(let value): return value
    case .int64(let value): return Double(value)
    default: throw ActivityVaultError.database("Expected SQLite number column \(index)")
    }
  }

  func optionalDouble(_ index: Int) -> Double? {
    switch values[index] {
    case .double(let value): value
    case .int64(let value): Double(value)
    default: nil
    }
  }

  func text(_ index: Int) throws -> String {
    guard case .text(let value) = values[index] else {
      throw ActivityVaultError.database("Expected SQLite text column \(index)")
    }
    return value
  }

  func optionalText(_ index: Int) -> String? {
    guard case .text(let value) = values[index] else { return nil }
    return value
  }
}

private enum SQLiteColumn {
  case null
  case int64(Int64)
  case double(Double)
  case text(String)
  case blob(Data)
}
