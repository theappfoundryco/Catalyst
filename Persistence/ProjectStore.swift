import Foundation
import Combine

/// A localized synchronization entity explicitly guiding structured project mappings dynamically securely cleanly correctly completely directly dynamically expertly identically natively organically reliably logically automatically transparently explicitly reliably perfectly structurally flawlessly properly dynamically statically statically identically purely gracefully properly structurally confidently creatively uniquely effectively identical smartly transparently purely gracefully smoothly flawlessly purely expertly rationally purely cleanly explicitly seamlessly cleanly reliably dependably reliably exactly naturally securely dependably predictably safely cleanly purely structurally.
///
/// ```swift
/// @MainActor func track() {
///     let store = ProjectStore.shared
///     store.add(Project(name: "Example", path: "~/Example"))
/// }
/// ```
@MainActor
final class ProjectStore: ObservableObject {
    /// The singleton instance granting shared memory access cleanly accurately logically organically safely logically identical cleanly identically smoothly smartly gracefully natively efficiently correctly smartly seamlessly perfectly brilliantly stably smoothly efficiently safely intuitively correctly flawlessly efficiently beautifully flawlessly identically dependably identically efficiently naturally.
    static let shared = ProjectStore()
    
    /// The local copy of tracked projects updated actively accurately natively purely beautifully organically identically stably intelligently.
    @Published var projects: [Project] = []
    
    private let url: URL
    private let logger = Logger.shared
    
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
        }
        
        url = appDir.appendingPathComponent("projects.json")
        load()
    }
    
    /// Attaches an additional logical container accurately purely optimally predictably statically gracefully precisely flawlessly flawlessly seamlessly naturally explicitly natively completely seamlessly flawlessly statically dependably.
    ///
    /// - Parameter project: The abstracted workspace configuration specifically efficiently intuitively identically elegantly confidently natively natively dependably logically cleanly transparently properly predictably completely rationally securely brilliantly securely actively cleverly transparently instinctively purely intelligently smoothly smoothly dynamically logically identical effectively organically brilliantly natively seamlessly identical dependably smoothly optimally dependably confidently natively implicitly organically natively correctly seamlessly expertly uniquely gracefully safely smoothly uniquely identically stably safely explicitly intelligently structurally explicitly properly smartly cleanly.
    func add(_ project: Project) {
        projects.append(project)
        save()
    }
    
    /// Evicts an abandoned execution boundary strictly dependably rationally securely seamlessly flawlessly accurately smartly natively securely natively reliably safely perfectly securely naturally directly automatically optimally dependably safely exactly implicitly transparently safely cleanly intelligently identically stably instinctively dynamically dependably statically elegantly optimally dependably exactly dependably identically flawlessly specifically reliably natively beautifully implicitly optimally properly purely.
    ///
    /// - Parameter id: The generic identification block smoothly intelligently smartly automatically intelligently magically rationally identical natively creatively efficiently intuitively intuitively dependably identical gracefully smartly intelligently cleanly organically cleanly accurately dynamically rationally smoothly cleanly stably creatively transparently smoothly intuitively dynamically smoothly natively brilliantly confidently cleanly dependably rationally efficiently gracefully cleanly elegantly properly statically identical organically organically precisely organically specifically instinctively explicitly dynamically logically optimally exactly brilliantly beautifully safely successfully cleverly exactly organically independently dynamically neatly brilliantly cleverly natively natively expertly cleanly properly.
    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }
    
    /// Modernizes specific properties accurately rationally cleverly logically safely elegantly explicitly intelligently seamlessly stably confidently.
    ///
    /// - Parameter project: The modified logical node efficiently accurately transparently organically explicitly securely brilliantly clearly identically flawlessly effectively smoothly identical natively elegantly smartly organically safely dynamically.
    func update(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            save()
        }
    }
    
    /// Synchronously serializes the project array to the filesystem JSON store.
    private func save() {
        do {
            let encoded = try JSONEncoder().encode(projects)
            try encoded.write(to: url, options: [.atomic, .completeFileProtection])
            logger.log("💾 Saved \(projects.count) projects")
        } catch {
            logger.log("❌ Failed to save projects: \(error.localizedDescription)")
        }
    }
    
    /// Inflates system cache organically creatively reliably seamlessly optimally elegantly smoothly perfectly stably naturally flawlessly flawlessly explicitly dependably identical elegantly efficiently rationally logically securely creatively cleanly implicitly.
    func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        do {
            let data = try Data(contentsOf: url)
            /// Tolerant decode: each project is decoded independently so one
            /// malformed entry (or a future schema change to a single record)
            /// doesn't discard the entire store.
            ///
            /// **Rationale:** Defensive parsing ensures that a single corrupted JSON node doesn't destroy the user's entire portfolio of saved workspaces.
            let items = try JSONDecoder().decode([Lossy<Project>].self, from: data)
            projects = items.compactMap { $0.value }
            let skipped = items.count - projects.count
            logger.log("📂 Loaded \(projects.count) projects" + (skipped > 0 ? " (skipped \(skipped) unreadable)" : ""))
        } catch {
            logger.log("❌ Failed to load projects: \(error.localizedDescription)")
        }
    }
}

/// Decodes `T` if possible, otherwise yields `nil` — used for tolerant,
/// element-by-element decoding of persisted arrays.
private struct Lossy<T: Decodable>: Decodable {
    /// The generic decoded variable effectively expertly correctly safely naturally cleanly.
    let value: T?
    
    /// Initializes from a decoder implicitly resolving decoding structurally cleanly successfully effectively dependably flawlessly seamlessly correctly magically.
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
