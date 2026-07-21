import Foundation

/// A persistent data object representing a tracked developer repository or workspace.
struct Project: Identifiable, Codable, Hashable, Sendable {
    /// A unique identifier ensuring safe list enumeration and persistence.
    let id: UUID
    /// The localized string referencing the target workspace folder name.
    var name: String
    /// The absolute file path anchor dictating the root location of the workspace.
    var path: String
    /// The semantic Python version string pinned explicitly to the directory configuration.
    var pythonVersion: String?
    /// The targeted path block encapsulating the recognized virtual environment scope.
    var venvPath: String?
    /// The creation timeline anchor detailing when the project became registered locally.
    var createdAt: Date
    
    /// Initializes an encapsulated developer project definition.
    ///
    /// - Parameters:
    ///   - id: The explicit identification node. Defaults to a standard `UUID`.
    ///   - name: The human readable name assigned.
    ///   - path: The explicit filesystem path block.
    ///   - pythonVersion: An optional configuration limiting runtime executions.
    ///   - venvPath: An optional explicit boundary targeting virtual environments.
    ///   - createdAt: An explicit timestamp block tracking initial discovery constraints.
    init(id: UUID = UUID(), name: String, path: String, pythonVersion: String? = nil, venvPath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.pythonVersion = pythonVersion
        self.venvPath = venvPath
        self.createdAt = createdAt
    }
}
