import Foundation

/// A utility struct designed to calculate storage metrics for directories on the file system.
struct ScannerUtils {
    
    /// Recursively calculates the aggregated size of a complete folder structure utilizing the native `FileManager`.
    ///
    /// - Important: This method performs synchronous file I/O operations. It must be called exclusively from
    ///   a background execution thread or via `Task.detached`, never from the main actor.
    ///
    /// - Parameter url: The localized directory `URL` target pointing to the base folder.
    /// - Returns: The total calculated allocation size represented in bytes.
    static func calculateSize(url: URL) -> Int64 {
        let resourceKeys: [URLResourceKey] = [.fileSizeKey, .totalFileSizeKey]
        var size: Int64 = 0
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) {
                if let fileSize = resourceValues.totalFileSize {
                    size += Int64(fileSize)
                } else if let fileSize = resourceValues.fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        
        return size
    }
}
