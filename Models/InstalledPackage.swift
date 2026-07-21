import Foundation

/// A minimal record identifying a successfully configured software package currently residing inside local system parameters.
struct InstalledPackage {
    /// The designated system identifier token required during standard CLI calls.
    let name: String
    /// An optional string describing semantic release versions.
    let version: String?
}
