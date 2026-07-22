import Foundation

/// A decodable schema representing static software release details fetched from a remote endpoint.
struct AppInfoResponse: Codable {
    /// The recognized commercial title of the target application.
    let appName: String
    /// The organization backing the primary development lifecycle.
    let developer: String
    /// The designated entity retaining the legal distribution rights.
    let copyright: String
    /// The primary remote anchor for documentation operations.
    let website: String?
    /// The directed pipeline for technical queries.
    let email: String?
    /// The generic pipeline for unstructured user thoughts.
    let feedback: String?
    /// The pipeline capturing documented execution faults.
    let bugReport: String?
    /// The pipeline for requesting new features.
    let featureRequest: String?
    /// The social profile of the developer.
    let connectWithDeveloper: String?
    /// The recognized semantic string representing the most recent release candidate.
    let latest: String
    /// A dictionary encompassing historic and active release cycles mapped to distinct structural changes.
    let versions: [String: VersionInfo]
    
    /// JSON mapping keys for the root metadata layer.
    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bugReport = "bug_report"
        case featureRequest = "feature_request"
        case connectWithDeveloper = "connect_with_developer"
        case developer, copyright, website, email, feedback, latest, versions
    }
}

/// A decodable schema detailing isolated deployment environments tied to a single semantic version instance.
struct VersionInfo: Codable {
    /// The ISO standardized temporal layout noting exact deployment launch coordinates.
    let releaseDate: String
    /// A condensed identifier summing up the primary feature vector.
    let tagline: String
    /// A localized array enumerating fundamental user-facing alterations.
    let highlights: [String]
    /// Hardware specifications strictly necessary for system deployment.
    let requirements: String
    
    /// JSON mapping keys for version-specific payload attributes.
    enum CodingKeys: String, CodingKey {
        case releaseDate = "release_date"
        case tagline, highlights, requirements
    }
}
