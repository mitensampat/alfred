import Foundation
import SQLite3

/// Simple SQLite-based cache for API query results
class QueryCacheService {
    private var db: OpaquePointer?
    private let dbPath: String
    private let cacheDuration: TimeInterval = 3600 // 1 hour default

    init() {
        // Store cache in user's temp directory
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent("alfred_cache.db").path

        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("⚠️  Failed to open cache database")
        }
    }

    private func createTable() {
        let createTableQuery = """
        CREATE TABLE IF NOT EXISTS query_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cache_key TEXT UNIQUE NOT NULL,
            endpoint TEXT NOT NULL,
            params TEXT,
            response TEXT NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cache_key ON query_cache(cache_key);
        CREATE INDEX IF NOT EXISTS idx_expires_at ON query_cache(expires_at);
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print("⚠️  Failed to create cache table")
            }
        }
        sqlite3_finalize(statement)
    }

    /// Generate cache key from endpoint and parameters
    private func generateCacheKey(endpoint: String, params: [String: String]) -> String {
        let sortedParams = params.sorted { $0.key < $1.key }
        let paramString = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(endpoint)?\(paramString)"
    }

    /// Get cached response if valid
    func getCached(endpoint: String, params: [String: String] = [:]) -> String? {
        let cacheKey = generateCacheKey(endpoint: endpoint, params: params)
        let now = Date().timeIntervalSince1970

        let query = """
        SELECT response, expires_at FROM query_cache
        WHERE cache_key = ? AND expires_at > ?
        """

        var statement: OpaquePointer?
        var result: String?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (cacheKey as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, now)

            if sqlite3_step(statement) == SQLITE_ROW {
                if let responsePtr = sqlite3_column_text(statement, 0) {
                    result = String(cString: responsePtr)
                    print("✅ Cache HIT for \(endpoint)")
                }
            } else {
                print("❌ Cache MISS for \(endpoint)")
            }
        }

        sqlite3_finalize(statement)
        return result
    }

    /// Cache a response
    func cache(endpoint: String, params: [String: String] = [:], response: String, ttl: TimeInterval? = nil) {
        let cacheKey = generateCacheKey(endpoint: endpoint, params: params)
        let now = Date().timeIntervalSince1970
        let expiresAt = now + (ttl ?? cacheDuration)

        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let query = """
        INSERT OR REPLACE INTO query_cache
        (cache_key, endpoint, params, response, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (cacheKey as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (endpoint as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (paramsJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (response as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 5, now)
            sqlite3_bind_double(statement, 6, expiresAt)

            if sqlite3_step(statement) == SQLITE_DONE {
                print("✅ Cached response for \(endpoint)")
            }
        }

        sqlite3_finalize(statement)
    }

    /// Clear expired cache entries
    func clearExpired() {
        let now = Date().timeIntervalSince1970
        let query = "DELETE FROM query_cache WHERE expires_at <= ?"

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, now)
            if sqlite3_step(statement) == SQLITE_DONE {
                let deleted = sqlite3_changes(db)
                if deleted > 0 {
                    print("🗑️  Cleared \(deleted) expired cache entries")
                }
            }
        }
        sqlite3_finalize(statement)
    }

    /// Clear all cache
    func clearAll() {
        let query = "DELETE FROM query_cache"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        print("🗑️  Cleared all cache")
    }

    /// Get recent queries
    func getRecentQueries(limit: Int = 10) -> [(endpoint: String, params: String, timestamp: Date)] {
        let query = """
        SELECT DISTINCT endpoint, params, created_at
        FROM query_cache
        ORDER BY created_at DESC
        LIMIT ?
        """

        var results: [(String, String, Date)] = []
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))

            while sqlite3_step(statement) == SQLITE_ROW {
                let endpoint = String(cString: sqlite3_column_text(statement, 0))
                let params = String(cString: sqlite3_column_text(statement, 1))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                results.append((endpoint, params, timestamp))
            }
        }

        sqlite3_finalize(statement)
        return results
    }

    /// Delete a specific cache entry by endpoint and params
    func deleteEntry(endpoint: String, params: [String: String]) -> Bool {
        let cacheKey = generateCacheKey(endpoint: endpoint, params: params)

        let query = "DELETE FROM query_cache WHERE cache_key = ?"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (cacheKey as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                print("🗑️  Deleted cache entry for \(endpoint)")
                return true
            }
        }

        sqlite3_finalize(statement)
        return false
    }
}
