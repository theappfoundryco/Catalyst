import XCTest
@testable import Catalyst

/// Comprehensive VersionComparator tests - NO MERCY approach
/// Tests every edge case, malformed input, and boundary condition
final class VersionComparatorTests: XCTestCase {
    
    // MARK: - Basic Comparison Tests
    
    func testCompare_SimpleVersions() {
        // Less than
        XCTAssertTrue(VersionComparator.compare("1.0", "2.0") < 0)
        XCTAssertTrue(VersionComparator.compare("1.0", "1.1") < 0)
        XCTAssertTrue(VersionComparator.compare("1.0.0", "1.0.1") < 0)
        
        // Greater than
        XCTAssertTrue(VersionComparator.compare("2.0", "1.0") > 0)
        XCTAssertTrue(VersionComparator.compare("1.1", "1.0") > 0)
        XCTAssertTrue(VersionComparator.compare("1.0.1", "1.0.0") > 0)
        
        // Equal
        XCTAssertTrue(VersionComparator.compare("1.0", "1.0") == 0)
        XCTAssertTrue(VersionComparator.compare("1.0.0", "1.0.0") == 0)
    }
    
    func testCompare_PythonVersions() {
        // Real Python version comparisons
        XCTAssertTrue(VersionComparator.compare("3.11", "3.12") < 0)
        XCTAssertTrue(VersionComparator.compare("3.9", "3.10") < 0)
        XCTAssertTrue(VersionComparator.compare("2.7", "3.0") < 0)
        XCTAssertTrue(VersionComparator.compare("3.12.1", "3.12.2") < 0)
        XCTAssertTrue(VersionComparator.compare("3.12", "3.11") > 0)
    }
    
    func testCompare_MajorVersionJumps() {
        XCTAssertTrue(VersionComparator.compare("2.999", "3.0") < 0)
        XCTAssertTrue(VersionComparator.compare("9.9.9", "10.0.0") < 0)
        XCTAssertTrue(VersionComparator.compare("99.99", "100.0") < 0)
    }
    
    // MARK: - Patch Version Tests
    
    func testCompare_PatchVersions() {
        XCTAssertTrue(VersionComparator.compare("3.12.0", "3.12.1") < 0)
        XCTAssertTrue(VersionComparator.compare("3.12.5", "3.12.10") < 0)
        XCTAssertTrue(VersionComparator.compare("3.12.10", "3.12.2") > 0)
        XCTAssertTrue(VersionComparator.compare("3.12.99", "3.12.100") < 0)
    }
    
    func testCompare_DeepVersions() {
        // 4+ parts
        XCTAssertTrue(VersionComparator.compare("1.2.3.4", "1.2.3.5") < 0)
        XCTAssertTrue(VersionComparator.compare("1.2.3.4.5", "1.2.3.4.6") < 0)
        XCTAssertTrue(VersionComparator.compare("1.2.3.4.5.6", "1.2.3.4.5.7") < 0)
    }
    
    // MARK: - Mixed Precision Tests
    
    func testCompare_MixedPrecision() {
        // Different number of version parts
        XCTAssertTrue(VersionComparator.compare("3.12", "3.12.0") == 0) // Should be equal
        XCTAssertTrue(VersionComparator.compare("3.12.0", "3.12") == 0)
        XCTAssertTrue(VersionComparator.compare("1", "1.0") == 0)
        XCTAssertTrue(VersionComparator.compare("1", "1.0.0") == 0)
        XCTAssertTrue(VersionComparator.compare("1.0.0.0", "1") == 0)
    }
    
    func testCompare_ImplicitZeros() {
        // Trailing zeros are implied
        XCTAssertTrue(VersionComparator.compare("1.0", "1.0.0.0.0") == 0)
        XCTAssertTrue(VersionComparator.compare("3.12", "3.12.0.0") == 0)
    }
    
    // MARK: - Edge Cases - Empty & Invalid
    
    func testCompare_EmptyStrings() {
        XCTAssertTrue(VersionComparator.compare("", "1.0") < 0)
        XCTAssertTrue(VersionComparator.compare("1.0", "") > 0)
        XCTAssertTrue(VersionComparator.compare("", "") == 0)
    }
    
    func testCompare_NonNumericParts() {
        // Non-numeric parts should be handled gracefully (converted to 0)
        let result1 = VersionComparator.compare("1.0.alpha", "1.0.0")
        // alpha becomes 0, so 1.0.0 == 1.0.0
        XCTAssertEqual(result1, 0)
        
        let result2 = VersionComparator.compare("1.0.1", "1.0.beta")
        // 1.0.1 vs 1.0.0 -> 1 > 0
        XCTAssertTrue(result2 > 0)
    }
    
    func testCompare_GarbageInput() {
        // Complete garbage should not crash
        _ = VersionComparator.compare("garbage", "nonsense")
        _ = VersionComparator.compare("...", "...")
        _ = VersionComparator.compare("   ", "   ")
        // If we get here without crashing, test passes
        XCTAssertTrue(true)
    }
    
    func testCompare_SpecialCharacters() {
        // Should handle without crashing
        _ = VersionComparator.compare("1.0-beta", "1.0-alpha")
        _ = VersionComparator.compare("v1.0", "v2.0")
        _ = VersionComparator.compare("1.0+build123", "1.0+build456")
        XCTAssertTrue(true)
    }
    
    // MARK: - Large Numbers
    
    func testCompare_LargeVersionNumbers() {
        XCTAssertTrue(VersionComparator.compare("1000.0.0", "999.9.9") > 0)
        XCTAssertTrue(VersionComparator.compare("1.1000000", "1.999999") > 0)
        XCTAssertTrue(VersionComparator.compare("999999.999999.999999", "999999.999999.999998") > 0)
    }
    
    func testCompare_IntegerOverflow() {
        // Test with very large numbers that could overflow Int32
        let huge1 = "9999999999.9999999999.9999999999"
        let huge2 = "9999999998.9999999999.9999999999"
        // Should handle without crashing
        _ = VersionComparator.compare(huge1, huge2)
        XCTAssertTrue(true)
    }
    
    // MARK: - isNewer Tests
    
    func testIsNewer_True() {
        XCTAssertTrue(VersionComparator.isNewer("2.0", than: "1.0"))
        XCTAssertTrue(VersionComparator.isNewer("3.12", than: "3.11"))
        XCTAssertTrue(VersionComparator.isNewer("1.0.1", than: "1.0.0"))
    }
    
    func testIsNewer_False() {
        XCTAssertFalse(VersionComparator.isNewer("1.0", than: "2.0"))
        XCTAssertFalse(VersionComparator.isNewer("1.0", than: "1.0")) // Equal is not newer
        XCTAssertFalse(VersionComparator.isNewer("3.11", than: "3.12"))
    }
    
    // MARK: - isOlder Tests
    
    func testIsOlder_True() {
        XCTAssertTrue(VersionComparator.isOlder("1.0", than: "2.0"))
        XCTAssertTrue(VersionComparator.isOlder("3.11", than: "3.12"))
        XCTAssertTrue(VersionComparator.isOlder("1.0.0", than: "1.0.1"))
    }
    
    func testIsOlder_False() {
        XCTAssertFalse(VersionComparator.isOlder("2.0", than: "1.0"))
        XCTAssertFalse(VersionComparator.isOlder("1.0", than: "1.0")) // Equal is not older
        XCTAssertFalse(VersionComparator.isOlder("3.12", than: "3.11"))
    }
    
    // MARK: - requiresBreakSystemPackages Tests
    
    func testRequiresBreakSystemPackages_Python312Plus() {
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.12"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.12.0"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.12.5"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.13"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.13.0"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.99"))
    }
    
    func testRequiresBreakSystemPackages_Python4Plus() {
        // Python 4+ should also require it
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "4.0"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "4.0.0"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "5.0"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "10.0"))
    }
    
    func testRequiresBreakSystemPackages_Python311AndBelow() {
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.11"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.11.9"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.10"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.9"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.8"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.0"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "2.7"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "2.0"))
    }
    
    func testRequiresBreakSystemPackages_EdgeCases() {
        // Exactly at boundary
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.11.99"))
        XCTAssertTrue(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3.12.0"))
        
        // Malformed input - should not crash
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: ""))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "3"))
        XCTAssertFalse(VersionComparator.requiresBreakSystemPackages(pythonVersion: "garbage"))
    }
    
    // MARK: - Sorting Tests
    
    func testSortedAscending() {
        let unsorted = ["3.12", "3.9", "3.11", "3.10"]
        let sorted = VersionComparator.sortedAscending(unsorted)
        XCTAssertEqual(sorted, ["3.9", "3.10", "3.11", "3.12"])
    }
    
    func testSortedDescending() {
        let unsorted = ["3.12", "3.9", "3.11", "3.10"]
        let sorted = VersionComparator.sortedDescending(unsorted)
        XCTAssertEqual(sorted, ["3.12", "3.11", "3.10", "3.9"])
    }
    
    func testSortedAscending_Complex() {
        let unsorted = ["1.0", "1.0.1", "0.9", "1.0.0", "2.0"]
        let sorted = VersionComparator.sortedAscending(unsorted)
        XCTAssertEqual(sorted, ["0.9", "1.0", "1.0.0", "1.0.1", "2.0"])
    }
    
    func testSortedAscending_Empty() {
        let empty: [String] = []
        let sorted = VersionComparator.sortedAscending(empty)
        XCTAssertEqual(sorted, [])
    }
    
    func testSortedAscending_SingleElement() {
        let single = ["3.12"]
        let sorted = VersionComparator.sortedAscending(single)
        XCTAssertEqual(sorted, ["3.12"])
    }
    
    func testSortedAscending_LargeArray() {
        var versions: [String] = []
        for major in 0..<10 {
            for minor in 0..<10 {
                versions.append("\(major).\(minor)")
            }
        }
        let sorted = VersionComparator.sortedAscending(versions)
        // First should be 0.0, last should be 9.9
        XCTAssertEqual(sorted.first, "0.0")
        XCTAssertEqual(sorted.last, "9.9")
    }
}
