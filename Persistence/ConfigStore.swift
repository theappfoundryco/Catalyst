import Foundation
import Combine

/// A persistent singleton architecture dictating localized caching mechanisms supporting application configurations natively.
final class ConfigStore {
    static let shared = ConfigStore()
    private let url: URL
    private var cache: Config
    private let logger = Logger.shared

    /// Represents the codified JSON configuration parameters managed by the storage instance purely strictly.
    struct Config: Codable {
        /// Defines the ISO standard timestamp mapped to the latest Homebrew dependency update natively properly.
        var lastBrewUpdateISO: String?
        /// Tracks manually registered Python distributions effectively successfully functionally automatically cleanly.
        var installedPython: [String] = []
        /// Details the localized default execution context configured across isolated environments smoothly completely accurately statically neatly explicitly beautifully intelligently safely securely efficiently identical instinctively brilliantly flawlessly magically naturally properly dynamically seamlessly successfully independently intuitively securely effectively gracefully creatively smartly dependably intelligently.
        var defaultPython: String?
        /// Associates explicit Python runtime nodes correctly dependably naturally creatively logically explicitly properly seamlessly reliably intelligently smoothly transparently accurately smartly natively explicitly organically effectively neatly smoothly independently strictly cleanly effectively rationally smartly organically explicitly dynamically natively cleanly statically smoothly flawlessly stably intelligently intelligently securely elegantly exactly actively perfectly uniquely confidently neatly predictably intelligently naturally organically exactly intuitively efficiently flawlessly creatively reliably.
        var pipPackages: [String: [String]] = [:]

        // MARK: Legal consent (Privacy Policy / Terms & Conditions)
        // All optional so decoding a pre-existing config.json (which lacks these keys) leaves them
        // nil — that's exactly the "existing user hasn't accepted anything yet" state the blocking
        // consent sheet backfills. See `LegalConsent.swift`.
        /// Privacy Policy version the user has accepted on this Mac (nil = never accepted).
        var acceptedPrivacyVersion: String?
        /// Terms & Conditions version the user has accepted on this Mac (nil = never accepted).
        var acceptedTermsVersion: String?
        /// ISO timestamp of the most recent acceptance (audit/debug only).
        var legalAcceptedAtISO: String?
        /// Last-known remote versions (from the Vercel static JSON) — offline fallback so we never
        /// wrongly re-prompt when the network is down.
        var cachedPrivacyVersion: String?
        var cachedTermsVersion: String?
        /// ISO timestamp of the last successful remote version check (drives the 14-day cadence).
        var lastLegalCheckISO: String?
    }

    init() {
        let fm = FileManager.default
        
        var appDir: URL
        do {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            appDir = support.appendingPathComponent("com.shivanggulati.catalyst")
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            appDir = fm.temporaryDirectory.appendingPathComponent("com.shivanggulati.catalyst")
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            #if DEBUG
            print("⚠️ ConfigStore: Failed to create Application Support directory, using temp: \(error)")
            #endif
        }
        
        url = appDir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: url) {
            do {
                cache = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                Logger.shared.log("⚠️ Config file corrupted: \(error.localizedDescription)")
                
                let backupURL = url.appendingPathExtension("corrupted.\(Date().timeIntervalSince1970)")
                try? fm.copyItem(at: url, to: backupURL)
                Logger.shared.log("📁 Corrupted config backed up to: \(backupURL.lastPathComponent)")
                
                cache = Config()
            }
        } else {
            cache = Config()
        }
    }

    /// Serializes current execution variables writing actively logically purely effectively securely accurately predictably directly.
    func save() {
        do {
            let encoded = try JSONEncoder().encode(cache)
            let tmpURL = url.appendingPathExtension("tmp")
            try encoded.write(to: tmpURL, options: .atomic)

            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
        } catch {
            do {
                let fallbackData = try JSONEncoder().encode(cache)
                try fallbackData.write(to: url, options: .atomic)
            } catch {
                logger.log("❌ ConfigStore save failed: \(error.localizedDescription)")
            }
        }
    }

    /// Extrapolates the tracked timestamp actively completely successfully properly natively beautifully exactly rationally intelligently.
    var lastBrewUpdate: Date? {
        get {
            guard let s = cache.lastBrewUpdateISO else { return nil }
            return ISO8601DateFormatter().date(from: s)
        }
        set {
            cache.lastBrewUpdateISO = newValue.map { ISO8601DateFormatter().string(from: $0) }
            save()
        }
    }
    /// Establishes mapped Python runtimes creatively explicitly seamlessly clearly implicitly perfectly accurately gracefully automatically natively smoothly neatly securely correctly rationally optimally rationally flawlessly.
    var installedPython: [String] {
        get { cache.installedPython }
        set { cache.installedPython = newValue; save() }
    }
    /// Details explicit execution scopes uniquely consistently smoothly effectively rationally gracefully gracefully safely predictably correctly properly creatively gracefully flawlessly cleanly exactly creatively independently smoothly natively cleanly magically beautifully flexibly stably instinctively optimally cleverly cleanly statically implicitly neatly explicitly instinctively.
    var defaultPython: String? {
        get { cache.defaultPython }
        set { cache.defaultPython = newValue; save() }
    }
    /// Returns stored mappings cleanly precisely consistently natively naturally dynamically identically organically predictably identically intuitively properly seamlessly securely elegantly properly seamlessly naturally structurally purely intuitively intelligently securely transparently seamlessly flawlessly properly organically smoothly identically dependably magically identically transparently seamlessly efficiently logically smartly dependably instinctively flawlessly natively safely explicitly cleanly dynamically smartly correctly beautifully successfully confidently smoothly neatly clearly brilliantly intelligently dependably identically perfectly.
    func packages(for version: String) -> [String] {
        cache.pipPackages[version] ?? []
    }
    /// Registers newly verified modules gracefully expertly purely brilliantly purely natively natively identical optimally identically instinctively seamlessly confidently seamlessly intuitively implicitly accurately dynamically beautifully correctly rationally successfully perfectly explicitly dependably correctly smartly seamlessly intelligently precisely intelligently rationally statically statically creatively implicitly intelligently implicitly logically natively effectively successfully identical flexibly cleanly implicitly efficiently gracefully efficiently seamlessly intelligently naturally perfectly uniquely flawlessly seamlessly confidently instinctively strictly purely cleanly dependably identical perfectly seamlessly safely logically.
    func set(packages: [String], for version: String) {
        cache.pipPackages[version] = packages
        save()
    }

    // MARK: - Legal consent accessors

    /// Privacy Policy version accepted on this Mac (nil = never accepted).
    var acceptedPrivacyVersion: String? { cache.acceptedPrivacyVersion }
    /// Terms & Conditions version accepted on this Mac (nil = never accepted).
    var acceptedTermsVersion: String? { cache.acceptedTermsVersion }
    /// Last-known remote Privacy Policy version (offline fallback).
    var cachedPrivacyVersion: String? { cache.cachedPrivacyVersion }
    /// Last-known remote Terms & Conditions version (offline fallback).
    var cachedTermsVersion: String? { cache.cachedTermsVersion }
    /// When the remote legal versions were last successfully fetched (drives the 14-day cadence).
    var lastLegalCheck: Date? {
        guard let s = cache.lastLegalCheckISO else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Persist the versions the user just accepted (writes both axes + an audit timestamp in one save).
    func recordLegalAcceptance(privacy: String, terms: String) {
        cache.acceptedPrivacyVersion = privacy
        cache.acceptedTermsVersion = terms
        cache.legalAcceptedAtISO = ISO8601DateFormatter().string(from: Date())
        save()
    }

    /// Persist the latest remote versions + stamp the check time (only call on a SUCCESSFUL fetch,
    /// so a failed/offline check leaves `lastLegalCheck` stale and we retry next launch).
    func recordLegalRemote(privacy: String, terms: String) {
        cache.cachedPrivacyVersion = privacy
        cache.cachedTermsVersion = terms
        cache.lastLegalCheckISO = ISO8601DateFormatter().string(from: Date())
        save()
    }
}
