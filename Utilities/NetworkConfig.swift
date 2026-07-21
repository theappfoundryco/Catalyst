import Foundation
import CryptoKit

/// A namespace for application-wide constants.
struct AppConstants {
    /// The URL endpoint for fetching the latest pip JSON data from PyPI.
    static let pypiPipURL = "https://pypi.org/pypi/pip/json"
}

/// A configuration interface for network sessions and associated endpoints.
///
/// `NetworkConfig` enforces specific timeout requirements for general API requests
/// versus long-running downloads to ensure responsive networking behavior.
enum NetworkConfig {
    
    /// A configured `URLSession` designed for quick, lightweight API requests.
    static let apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    /// A configured `URLSession` designed for large payload downloads.
    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    /// A namespace containing static endpoint strings for Catalyst's read-only data.
    ///
    /// Everything here is a **static JSON file on a CDN** — there is no API, no server, and no
    /// request that carries anything about the user. Catalyst reads catalogs; it never writes.
    ///
    /// Hosting is GitHub Pages behind a custom domain. The domain is the point: `SUFeedURL` and
    /// these paths get compiled into builds that live on people's machines for years, so the
    /// indirection has to be something we can repoint forever. A CNAME can move to any host; a
    /// `*.pages.dev` or `*.github.io` URL is a permanent dependency on one vendor. Catalyst has
    /// already been stranded once this way — the Cloudflare Pages project these paths used to
    /// point at was deleted, and every catalog screen went blank behind `RemoteCache`'s
    /// stale-on-error fallback.
    enum APIEndpoint {
        /// The base URL for Catalyst's static data. CNAME → GitHub Pages.
        static let baseURL = "https://data.theappfoundry.co/catalyst"
        /// The endpoint for the public static assets directory.
        static let publicURL = "\(baseURL)/public"
        /// The endpoint for shortcuts data.
        static let shortcutsURL = "\(publicURL)/shortcuts"
        /// The endpoint for Homebrew-related static assets.
        static let brewURL = "\(publicURL)/brew"
        /// The endpoint for PyPI-related static assets.
        static let pypiURL = "\(publicURL)/pypi"
        /// The endpoint for popular package indexes.
        static let popularURL = "\(publicURL)/popular"

        /// Lightweight liveness probe — a tiny static file on the same host as the catalogs.
        ///
        /// Deliberately points at the DATA host rather than anything else: the question this
        /// answers is "can Catalyst reach its content?", so probing a different origin would
        /// report healthy while every catalog screen sits empty.
        static let healthURL = "\(baseURL)/health.json"
        /// The endpoint providing the supported Homebrew formulae JSON payload.
        static let brewFormulaeURL = "\(brewURL)/homebrew_formulae.json"
        /// The endpoint providing the supported Homebrew casks JSON payload.
        static let brewCasksURL = "\(brewURL)/homebrew_casks.json"
        // NOTE: `aboutURL` was removed — "About / What's new" now ships bundled in the app
        // (Resources `about.json`), not fetched remotely. See AboutViewModel.
    }
    
    /// The single, centralized entry point for fetching + decoding remote JSON.
    ///
    /// All remote (Cloudflare) reads route through here. Backed by `RemoteCache`:
    /// a payload younger than `ttl` is served from disk without a network hit; a
    /// stale one is refetched; on a network failure a stale cached copy is
    /// returned rather than throwing (offline-safe).
    ///
    /// - Parameters:
    ///   - url: The network URL to fetch the data from.
    ///   - type: The `Decodable` type expected in the response.
    ///   - ttl: How long a cached copy stays fresh. Use a `CacheTTL` constant.
    ///          Defaults to `CacheTTL.never` (no caching) so existing callers are
    ///          unchanged until they opt into a TTL.
    static func fetchJSON<T: Decodable>(
        from url: URL,
        as type: T.Type,
        ttl: TimeInterval = CacheTTL.never
    ) async throws -> T {
        try await RemoteCache.shared.fetch(url, as: type, ttl: ttl)
    }
    
    /// Represents errors triggered during network configurations and requests.
    enum NetworkError: Error, LocalizedError {
        /// Indicates an unparseable or totally missing HTTP response object.
        case invalidResponse
        /// Indicates a non-200 level standard HTTP status code.
        case httpError(statusCode: Int)
        /// Indicates a failure decoding the payload into the expected JSON shape.
        case decodingError(underlying: Error)
        
        /// A localized readable description of the network error.
        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .decodingError(let underlying):
                return "Failed to decode response: \(underlying.localizedDescription)"
            }
        }
    }
}

// MARK: - Remote cache (centralized fetch caching)

/// Stale timeouts per remote resource. One place controls how long each payload is
/// served from cache before a refetch. These are the **max-safe** values: the refresh
/// button busts the cache (`RemoteCache.clearAll`) and stale-on-error covers offline, so
/// TTLs are set by how often each payload actually changes, not by freshness paranoia.
enum CacheTTL {
    static let shortcutsIndex: TimeInterval  =  7 * 24 * 60 * 60  // shortcuts/index.json — authored; you control publish cadence
    static let shortcutDetail: TimeInterval  =  7 * 24 * 60 * 60  // shortcuts/<id>.json
    static let brewCatalog: TimeInterval     =  7 * 24 * 60 * 60  // brew/homebrew_*.json (~1MB) — a new formula can wait days
    static let pypiShard: TimeInterval       = 48 * 60 * 60       // pypi/<prefix>.json — kept shortest (most "live" search data)
    static let popular: TimeInterval         = 30 * 24 * 60 * 60  // popular/*.json — hand-curated, rarely changes

    /// Opt-out sentinel: always hit the network, never serve/store cache.
    static let never: TimeInterval = 0
}

/// Disk-backed cache for remote payloads, keyed by URL. Actor-isolated so it's
/// safe to call from any context. Reached via `NetworkConfig.fetchJSON(from:as:ttl:)`.
actor RemoteCache {
    static let shared = RemoteCache()

    private let dir: URL
    private let fm = FileManager.default

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.shivanggulati.catalyst/RemoteCache", isDirectory: true)
        self.dir = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Fetch + decode `url`, serving cache while it's younger than `ttl`.
    /// - `ttl == CacheTTL.never` bypasses the cache entirely.
    /// - On a network error, a stale cached copy (if any) is returned rather than throwing.
    func fetch<T: Decodable>(
        _ url: URL,
        as type: T.Type,
        ttl: TimeInterval,
        session: URLSession = NetworkConfig.apiSession
    ) async throws -> T {
        let file = cacheFile(for: url)

        // 1. Fresh cache hit → no network.
        if ttl > 0, let data = freshData(at: file, ttl: ttl) {
            return try JSONDecoder().decode(T.self, from: data)
        }

        // 2. Network fetch (validate status + decode before caching).
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw NetworkConfig.NetworkError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if ttl > 0 { try? data.write(to: file, options: .atomic) }
            return decoded
        } catch {
            // 3. Offline fallback: any stale copy beats an error.
            if ttl > 0, let data = try? Data(contentsOf: file),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
            throw error
        }
    }

    /// Drop all cached payloads (e.g. a "force refresh everything" action).
    func clearAll() {
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Drop the cached payload for a single URL (targeted refresh — leaves the
    /// large brew/pypi catalogs untouched).
    func clear(_ url: URL) {
        try? fm.removeItem(at: cacheFile(for: url))
    }

    private func freshData(at file: URL, ttl: TimeInterval) -> Data? {
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl,
              let data = try? Data(contentsOf: file) else { return nil }
        return data
    }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name).appendingPathExtension("json")
    }
}
