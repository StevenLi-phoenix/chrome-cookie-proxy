import Foundation
import SQLite3

struct CookieRow: Equatable {
    var hostKey: String
    var name: String
    var value: String
    var encryptedValue: Data
    var path: String
    var expiresUTC: Int64
    var isSecure: Bool
}

struct CookieDatabaseContents {
    var metaVersion: Int
    var rows: [CookieRow]
}

/// 读 Chrome 的 Cookies 库：先把库（连同 -wal、-journal）复制到私有临时目录，
/// 只读打开副本，用完删掉整个目录。绝不直接打开 Chrome 正在用的文件。
enum CookieDatabase {
    static func read(cookiesFile: URL, workRoot: URL, include: (String) -> Bool) throws -> CookieDatabaseContents {
        let work = try makeWorkDirectory(in: workRoot)
        defer { try? FileManager.default.removeItem(at: work) }

        let copy = work.appendingPathComponent("Cookies")
        try copyDatabase(from: cookiesFile, to: copy)

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ExportError.cookiesDBUnreadable("sqlite open: \(message)")
        }
        defer { sqlite3_close(db) }

        let version = try readMetaVersion(db)
        let rows = try readRows(db, include: include)
        return CookieDatabaseContents(metaVersion: version, rows: rows)
    }

    private static func makeWorkDirectory(in root: URL) throws -> URL {
        var template = Array(root.appendingPathComponent("ccp-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else {
            throw ExportError.cookiesDBUnreadable("mkdtemp errno \(errno)")
        }
        let path = String(cString: created)
        chmod(path, 0o700)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 先复制 -wal / -journal 再复制主库：主库复制完之后 Chrome 才做的 checkpoint
    /// 不会让副本丢帧（旧帧叠在新库上内容相同）。
    private static func copyDatabase(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        do {
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if fm.fileExists(atPath: side.path) {
                    try fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix))
                }
            }
            try fm.copyItem(at: source, to: dest)
        } catch {
            throw ExportError.cookiesDBUnreadable("copy: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    private static func readMetaVersion(_ db: OpaquePointer?) throws -> Int {
        let stmt = try prepare(db, "SELECT value FROM meta WHERE key='version'")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return text(stmt, 0).flatMap { Int($0) } ?? 0
        case SQLITE_DONE: return 0
        default: throw failure(db, "meta")
        }
    }

    private static func readRows(_ db: OpaquePointer?, include: (String) -> Bool) throws -> [CookieRow] {
        let stmt = try prepare(db, "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure FROM cookies")
        defer { sqlite3_finalize(stmt) }
        var rows: [CookieRow] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                let host = text(stmt, 0) ?? ""
                guard include(host) else { continue }
                let blobLength = Int(sqlite3_column_bytes(stmt, 3))
                let blob = blobLength > 0 ? Data(bytes: sqlite3_column_blob(stmt, 3), count: blobLength) : Data()
                rows.append(CookieRow(
                    hostKey: host,
                    name: text(stmt, 1) ?? "",
                    value: text(stmt, 2) ?? "",
                    encryptedValue: blob,
                    path: text(stmt, 4) ?? "",
                    expiresUTC: sqlite3_column_int64(stmt, 5),
                    isSecure: sqlite3_column_int(stmt, 6) != 0))
            case SQLITE_DONE:
                return rows
            default:
                throw failure(db, "cookies")
            }
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw failure(db, "prepare")
        }
        return stmt
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    private static func failure(_ db: OpaquePointer?, _ stage: String) -> ExportError {
        .cookiesDBUnreadable("sqlite \(stage): \(sqlite3_errcode(db)) \(String(cString: sqlite3_errmsg(db)))")
    }
}
