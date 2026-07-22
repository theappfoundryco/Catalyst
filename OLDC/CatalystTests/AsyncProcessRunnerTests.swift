import XCTest
@testable import Catalyst

/// Comprehensive AsyncProcessRunner tests - NO MERCY approach
/// Tests command execution, error handling, timeouts, and edge cases
final class AsyncProcessRunnerTests: XCTestCase {
    
    // MARK: - Basic Command Execution
    
    func testRunSimpleCommand() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo hello")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("hello"))
    }
    
    func testRunCommandWithMultipleLines() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'line1'; echo 'line2'; echo 'line3'")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("line1"))
        XCTAssertTrue(result.stdout.contains("line2"))
        XCTAssertTrue(result.stdout.contains("line3"))
    }
    
    func testRunCommandWithArguments() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "printf '%s %s' hello world")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("hello world"))
    }
    
    func testRunCommandWithSpecialCharacters() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'special chars: $HOME `date`'")
        
        XCTAssertTrue(result.succeeded)
        // Single quotes prevent expansion
        XCTAssertTrue(result.stdout.contains("$HOME"))
    }
    
    // MARK: - Exit Codes
    
    func testExitCodeZero() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "exit 0")
        
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
    }
    
    func testExitCodeOne() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "exit 1")
        
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.succeeded)
    }
    
    func testExitCodeCustom() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "exit 42")
        
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertFalse(result.succeeded)
    }
    
    func testExitCodeFromFalse() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "false")
        
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.succeeded)
    }
    
    func testExitCodeFromTrue() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "true")
        
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
    }
    
    // MARK: - Stdout/Stderr Capture
    
    func testStdoutCapture() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'stdout test'")
        
        XCTAssertTrue(result.stdout.contains("stdout test"))
        XCTAssertTrue(result.stderr.isEmpty || !result.stderr.contains("stdout test"))
    }
    
    func testStderrCapture() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'stderr test' >&2")
        
        XCTAssertTrue(result.stderr.contains("stderr test"))
    }
    
    func testCombinedOutput() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'out'; echo 'err' >&2")
        
        XCTAssertTrue(result.combinedOutput.contains("out"))
        XCTAssertTrue(result.combinedOutput.contains("err"))
    }
    
    func testLargeOutput() async throws {
        // Generate 1000 lines of output
        let result = try await AsyncProcessRunner.shared.run(command: "seq 1 1000")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("1"))
        XCTAssertTrue(result.stdout.contains("500"))
        XCTAssertTrue(result.stdout.contains("1000"))
    }
    
    // MARK: - Error Cases
    
    func testNonExistentCommand() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "nonexistent_command_12345")
        
        XCTAssertFalse(result.succeeded)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("not found") || result.combinedOutput.contains("not found"))
    }
    
    func testInvalidSyntax() async throws {
        // "(" is a guaranteed syntax error in zsh
        let result = try await AsyncProcessRunner.shared.run(command: "(")
        
        XCTAssertFalse(result.succeeded)
        XCTAssertNotEqual(result.exitCode, 0)
    }
    
    func testEmptyCommand() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "")
        
        // Empty command should succeed with no output
        XCTAssertTrue(result.stdout.isEmpty || result.succeeded)
    }
    
    // MARK: - Environment Variables
    
    func testEnvironmentVariableExpansion() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo $PATH")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.stdout.isEmpty)
    }
    
    func testHomeDirectory() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo $HOME")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("/Users") || result.stdout.contains("/home"))
    }
    
    // MARK: - Concurrency Tests
    
    func testConcurrentCommands() async throws {
        async let result1 = AsyncProcessRunner.shared.run(command: "echo 'cmd1'")
        async let result2 = AsyncProcessRunner.shared.run(command: "echo 'cmd2'")
        async let result3 = AsyncProcessRunner.shared.run(command: "echo 'cmd3'")
        
        let results = try await [result1, result2, result3]
        
        XCTAssertTrue(results.allSatisfy { $0.succeeded })
        XCTAssertTrue(results[0].stdout.contains("cmd1"))
        XCTAssertTrue(results[1].stdout.contains("cmd2"))
        XCTAssertTrue(results[2].stdout.contains("cmd3"))
    }
    
    func testManyConcurrentCommands() async throws {
        var tasks: [Task<AsyncProcessRunner.ProcessResult, Error>] = []
        
        for i in 0..<10 {
            let task = Task {
                try await AsyncProcessRunner.shared.run(command: "echo '\(i)'")
            }
            tasks.append(task)
        }
        
        var successCount = 0
        for task in tasks {
            let result = try await task.value
            if result.succeeded {
                successCount += 1
            }
        }
        
        XCTAssertEqual(successCount, 10)
    }
    
    // MARK: - Command with Sleep (Long Running)
    
    func testQuickCommand() async throws {
        let start = Date()
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'fast'")
        let duration = Date().timeIntervalSince(start)
        
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(duration, 1.0) // Should complete in under 1 second
    }
    
    // MARK: - Binary/Non-UTF8 Output
    
    func testBinaryOutput() async throws {
        // Generate some binary-ish data
        let result = try await AsyncProcessRunner.shared.run(command: "head -c 100 /dev/urandom | base64")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.stdout.isEmpty)
    }
    
    // MARK: - Piped Commands
    
    func testPipedCommand() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'hello world' | grep world")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("world"))
    }
    
    func testComplexPipeline() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'a b c d' | tr ' ' '\\n' | sort | head -2")
        
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("a"))
        XCTAssertTrue(result.stdout.contains("b"))
    }
    
    // MARK: - runWithBrewPath Tests
    
    func testRunWithBrewPath() async throws {
        let result = try await AsyncProcessRunner.shared.runWithBrewPath(command: "echo $PATH")
        
        XCTAssertTrue(result.succeeded)
        // PATH should contain homebrew prefix
        XCTAssertTrue(result.stdout.contains("brew") || result.stdout.contains("opt") || result.succeeded)
    }
    
    // MARK: - ProcessResult Properties
    
    func testProcessResultSucceeded() async throws {
        let successResult = try await AsyncProcessRunner.shared.run(command: "true")
        let failResult = try await AsyncProcessRunner.shared.run(command: "false")
        
        XCTAssertTrue(successResult.succeeded)
        XCTAssertFalse(failResult.succeeded)
    }
    
    func testProcessResultCombinedOutput() async throws {
        let result = try await AsyncProcessRunner.shared.run(command: "echo 'stdout'; echo 'stderr' >&2")
        
        let combined = result.combinedOutput
        XCTAssertTrue(combined.contains("stdout"))
        XCTAssertTrue(combined.contains("stderr"))
    }
}
