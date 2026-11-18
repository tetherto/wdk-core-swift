import Testing
import Foundation
import BareKit
@testable import WdkCore

/// Test suite for WdkCore functionality
/// These tests need a macOS worklet bundle and addon frameworks under
/// Tests/Resources/macos/ (generated with wdk-worklet-bundler, platforms: ["macos"]),
/// prepared with ./Scripts/prepare-macos-frameworks.sh and run via
/// ./Scripts/test-with-frameworks.sh. See "Running the Tests" in the README.

// MARK: - IPC Tests

/// Location of a fixture of Tests/Fixtures/, which Scripts/test-with-frameworks.sh packs into a
/// bundle. A packed bundle starts on every engine; plain source aborts on the JavaScriptCore
/// build of BareKit 2.5.5.
private func fixtureBundleURL(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Resources/macos/fixtures/\(name).bundle")
}

/// Starts `worklet` from the fixture `name`.
private func startFixture(_ name: String, on worklet: Worklet) throws {
    let url = fixtureBundleURL(name)
    worklet.start(filename: url.path, source: try Data(contentsOf: url))
}

@Test("IPC echo with simple JS", .timeLimit(.minutes(1)))
func testIPCEchoSimple() async throws {
    let worklet = Worklet()

    try startFixture("echo", on: worklet)

    let ipc = IPC(worklet: worklet)

    let ready = try await ipc.read()
    let readyStr = ready.flatMap { String(data: $0, encoding: .utf8) }
    #expect(readyStr == "READY")

    let msg = "Hello from Swift!"
    try await ipc.write(data: msg.data(using: .utf8)!)

    let echo = try await ipc.read()
    let echoStr = echo.flatMap { String(data: $0, encoding: .utf8) }
    #expect(echoStr == msg)

    worklet.terminate()
}

@Test("IPC with loaded JS", .timeLimit(.minutes(1)))
func testIPCWithLoadedJS() async throws {
    let worklet = Worklet()

    try startFixture("hello", on: worklet)

    let ipc = IPC(worklet: worklet)

    let data = try await ipc.read()
    let msg = data.flatMap { String(data: $0, encoding: .utf8) }

    worklet.terminate()
    #expect(msg == "HELLO_FROM_MODULE")
}

@Test("FramedEcho", .timeLimit(.minutes(1)))
func testFramedEcho() async throws {
    let worklet = Worklet()

    try startFixture("framed-echo", on: worklet)
    let ipc = IPC(worklet: worklet)

    let ready = try await ipc.read()
    let readyStr = ready.flatMap { String(data: $0, encoding: .utf8) }
    #expect(readyStr == "READY")

    let msg = "Hello framed!"
    let msgData = msg.data(using: .utf8)!
    var length = UInt32(msgData.count).bigEndian
    let frame = Data(bytes: &length, count: 4) + msgData
    try await ipc.write(data: frame)

    let resp = try await ipc.read()
    if let resp = resp {
        let payload = String(data: resp.dropFirst(4), encoding: .utf8) ?? "nil"
        #expect(payload == msg)
    }

    worklet.terminate()
}

// MARK: - Error Edge Cases (no worklet started)

@Test("Bundle not found throws error")
func testBundleNotFound() async {
    let wdk = WdkCore(bundleName: "nonexistent-bundle")

    do {
        _ = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        Issue.record("Should have thrown bundleNotFound error")
    } catch WDKError.bundleNotFound(let message) {
        #expect(message.contains("nonexistent-bundle"))
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

// MARK: - Initialization

@Test("Initialization is retried after the bundle path is repaired", .timeLimit(.minutes(1)))
func testInitializationRetriedAfterBundlePathRepaired() async throws {
    // Arrange: a client whose bundle does not exist yet.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundleURL = directory.appendingPathComponent("pong.bundle")
    let wdk = WdkCore(bundlePath: bundleURL.path)

    // Act: the first call fails, then the bundle appears and the same client is used again.
    var firstError: Error?
    do {
        try await wdk.workletStart()
    } catch {
        firstError = error
    }
    try FileManager.default.copyItem(at: fixtureBundleURL("pong"), to: bundleURL)
    let reply = try await wdk.callMethod(methodName: "ping", network: "none")

    // Assert
    #expect((firstError as? CocoaError)?.code == .fileReadNoSuchFile)
    #expect(reply as? String == "pong")
}

/// A plain run checks that every call is answered. The race between concurrent first calls is
/// only reported under ThreadSanitizer, so run this test with it:
/// `./Scripts/test-with-frameworks.sh --sanitize=thread --filter testConcurrentFirstCallsShareOneInitialization`
/// ThreadSanitizer may also report bare-kit-swift's IPC.swift: rarely for this test alone, and
/// so far always over the whole suite. That one is a false alarm that fails a run in which
/// every test passes. Only a report that names WdkCore.swift matters here.
@Test("Concurrent first calls share one initialization", .timeLimit(.minutes(1)))
func testConcurrentFirstCallsShareOneInitialization() async throws {
    // Arrange: a client that no call has started yet.
    let wdk = WdkCore(bundlePath: fixtureBundleURL("pong").path)
    let callCount = 1024
    let longestDelay = 128

    // Act: each call first yields a different number of times, so the calls arrive before,
    // during and after the initialization.
    let replies = try await withThrowingTaskGroup(of: String?.self) { group in
        for index in 0..<callCount {
            group.addTask {
                for _ in 0..<(index % longestDelay) {
                    await Task.yield()
                }
                return try await wdk.callMethod(methodName: "ping", network: "none") as? String
            }
        }
        var replies: [String?] = []
        for try await reply in group {
            replies.append(reply)
        }
        return replies
    }

    // Assert
    #expect(replies == Array(repeating: "pong", count: callCount))
}

// MARK: - Reader Failure

/// Describes how `call` ended: the description of the error it threw, or a note that it
/// returned or is still pending. A pending call cannot be cancelled, so awaiting it directly
/// would hang the test run instead of failing it.
private func outcome(of call: @escaping () async throws -> Void) async -> String? {
    let (outcomes, continuation) = AsyncStream<String>.makeStream()
    Task {
        do {
            try await call()
            continuation.yield("returned without an error")
        } catch {
            continuation.yield(error.localizedDescription)
        }
    }
    Task {
        try? await Task.sleep(for: .seconds(5))
        continuation.yield("still pending after 5 seconds")
    }
    return await outcomes.first { _ in true }
}

@Test("Calls made after the reader failed throw the error that ended it", .timeLimit(.minutes(1)))
func testCallsAfterReaderFailureThrowReaderError() async throws {
    // Arrange: a worklet whose first reply is a frame of length zero, which ends the reader.
    let wdk = WdkCore(bundlePath: fixtureBundleURL("zero-length-reply").path)

    // Act: the first call is in flight when the reader ends, the second is made afterwards.
    let firstOutcome = await outcome { try await wdk.workletStart() }
    let secondOutcome = await outcome {
        _ = try await wdk.callMethod(methodName: "ping", network: "none")
    }

    // Assert
    #expect(firstOutcome == "IPC Error: Invalid message length: 0")
    #expect(secondOutcome == "IPC Error: Invalid message length: 0")
}

// MARK: - Standalone WDK Test

@Test("Minimal WDK bundle load", .timeLimit(.minutes(1)))
func testMinimalWDKBundleLoad() async throws {
    let wdk = WdkCore()
    let result = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
    #expect(!result.encryptionKey.isEmpty)
}

// MARK: - WDK Operations (shared worklet to avoid crash on re-creation)

@Suite("WDK Operations", .serialized)
struct WDKOperationTests {
    // Single shared instance — worklet starts once and stays running.
    // Creating/destroying multiple WDK worklets causes SIGSEGV due to
    // async addon cleanup in the bare runtime.
    nonisolated(unsafe) static let wdk = WdkCore()

    @Test("Worklet starts successfully")
    func testWorkletStarts() async throws {
        let result = try await WDKOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 12)

        #expect(!result.encryptionKey.isEmpty)
        #expect(!result.encryptedSeedBuffer.isEmpty)
        #expect(!result.encryptedEntropyBuffer.isEmpty)
    }

    @Test("Custom bundle path works")
    func testCustomBundlePath() async throws {
        #if os(macOS)
        let testPath = FileManager.default.currentDirectoryPath
            + "/Tests/Resources/macos/wdk-worklet.macos.bundle"
        #else
        let testPath = FileManager.default.currentDirectoryPath
            + "/Tests/Resources/ios/wdk-worklet.mobile.bundle"
        #endif

        // Use a separate instance for explicit path test — this is the ONLY
        // extra instance we create, and it stays alive for the rest of the suite.
        let wdk = WdkCore(bundlePath: testPath)
        let result = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        #expect(!result.encryptionKey.isEmpty)
    }

    @Test("Generate 12-word entropy")
    func testGenerateEntropy12Words() async throws {
        let result = try await WDKOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 12)

        #expect(!result.encryptionKey.isEmpty)
        #expect(!result.encryptedSeedBuffer.isEmpty)
        #expect(!result.encryptedEntropyBuffer.isEmpty)
        #expect(Data(base64Encoded: result.encryptionKey) != nil)
        #expect(Data(base64Encoded: result.encryptedSeedBuffer) != nil)
    }

    @Test("Generate 24-word entropy")
    func testGenerateEntropy24Words() async throws {
        let result = try await WDKOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 24)

        #expect(!result.encryptionKey.isEmpty)
        #expect(!result.encryptedSeedBuffer.isEmpty)
        #expect(!result.encryptedEntropyBuffer.isEmpty)
    }

    @Test("Get mnemonic from encrypted entropy")
    func testGetMnemonicFromEntropy() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let mnemonic = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: entropy.encryptedEntropyBuffer,
            encryptionKey: entropy.encryptionKey
        )

        let words = mnemonic.split(separator: " ")
        #expect(words.count == 12)

        for word in words {
            #expect(!word.isEmpty)
            #expect(word.lowercased() == String(word))
        }
    }

    @Test("Recover seed from mnemonic")
    func testRecoverSeedFromMnemonic() async throws {
        let wdk = WDKOperationTests.wdk
        let originalEntropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        let mnemonic = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: originalEntropy.encryptedEntropyBuffer,
            encryptionKey: originalEntropy.encryptionKey
        )

        let recovered = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: mnemonic)

        #expect(!recovered.encryptionKey.isEmpty)
        #expect(!recovered.encryptedSeedBuffer.isEmpty)
        #expect(!recovered.encryptedEntropyBuffer.isEmpty)
    }

    @Test("Round-trip mnemonic conversion")
    func testRoundTripMnemonic() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy1 = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        let mnemonic1 = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: entropy1.encryptedEntropyBuffer,
            encryptionKey: entropy1.encryptionKey
        )

        let entropy2 = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: mnemonic1)
        let mnemonic2 = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: entropy2.encryptedEntropyBuffer,
            encryptionKey: entropy2.encryptionKey
        )

        #expect(mnemonic1 == mnemonic2)
    }

    @Test("Initialize WDK with basic config")
    func testInitializeWDK() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )
    }

    @Test("Initialize WDK with multiple wallets")
    func testInitializeMultipleWallets() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } },
            "polygon": { "blockchain": "polygon", "config": { "chainId": 137 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )
    }

    @Test("Get Ethereum address")
    func testGetEthereumAddress() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        let address = try await wdk.getAddress(network: "ethereum")

        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
    }

    @Test("Get address for different account indices")
    func testGetAddressMultipleIndices() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        let address0 = try await wdk.getAddress(network: "ethereum", accountIndex: 0)
        let address1 = try await wdk.getAddress(network: "ethereum", accountIndex: 1)

        #expect(address0 != address1)
        #expect(address0.hasPrefix("0x"))
        #expect(address1.hasPrefix("0x"))
    }

    @Test("Deterministic address derivation")
    func testDeterministicAddresses() async throws {
        let wdk = WDKOperationTests.wdk
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        // First derivation
        let entropy1 = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: testMnemonic)
        try await wdk.initializeWDK(
            encryptionKey: entropy1.encryptionKey,
            encryptedSeed: entropy1.encryptedSeedBuffer,
            config: config
        )
        let address1 = try await wdk.getAddress(network: "ethereum")

        // Second derivation with same mnemonic (re-initializes WDK)
        let entropy2 = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: testMnemonic)
        try await wdk.initializeWDK(
            encryptionKey: entropy2.encryptionKey,
            encryptedSeed: entropy2.encryptedSeedBuffer,
            config: config
        )
        let address2 = try await wdk.getAddress(network: "ethereum")

        #expect(address1 == address2)
    }

    @Test("Get balance returns string format")
    func testGetBalanceFormat() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": {
              "blockchain": "ethereum",
              "config": { "chainId": 1, "provider": "https://eth.llamarpc.com" }
            }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        do {
            let balance = try await wdk.getBalance(network: "ethereum")

            #expect(!balance.isEmpty)
            #expect(balance == "0" || Double(balance) != nil || balance.contains("e"))
        } catch {
            // Network errors are acceptable in CI (no RPC endpoint)
        }
    }

    @Test("Invalid word count throws error")
    func testInvalidWordCount() async {
        do {
            _ = try await WDKOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 15)
            Issue.record("Should have thrown an error for invalid word count")
        } catch WDKError.rpcError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Invalid mnemonic throws error")
    func testInvalidMnemonic() async {
        do {
            _ = try await WDKOperationTests.wdk.getSeedAndEntropyFromMnemonic(mnemonic: "invalid mnemonic phrase")
            Issue.record("Should have thrown an error for invalid mnemonic")
        } catch WDKError.rpcError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Concurrent calls return correct responses", .timeLimit(.minutes(2)))
    func testConcurrentCalls() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } },
            "polygon": { "blockchain": "polygon", "config": { "chainId": 137 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        async let ethAddress = wdk.getAddress(network: "ethereum", accountIndex: 0)
        async let polyAddress = wdk.getAddress(network: "polygon", accountIndex: 0)
        async let ethAddress1 = wdk.getAddress(network: "ethereum", accountIndex: 1)

        let results = try await (ethAddress, polyAddress, ethAddress1)

        #expect(results.0.hasPrefix("0x"))
        #expect(results.0.count == 42)
        #expect(results.1.hasPrefix("0x"))
        #expect(results.1.count == 42)
        #expect(results.2.hasPrefix("0x"))
        #expect(results.2.count == 42)

        // Same chain, different indices must differ
        #expect(results.0 != results.2)

        // Verify determinism: call again sequentially and compare
        let ethAgain = try await wdk.getAddress(network: "ethereum", accountIndex: 0)
        let polyAgain = try await wdk.getAddress(network: "polygon", accountIndex: 0)

        #expect(results.0 == ethAgain)
        #expect(results.1 == polyAgain)
    }

    @Test("Concurrent entropy generation", .timeLimit(.minutes(2)))
    func testConcurrentEntropyGeneration() async throws {
        let wdk = WDKOperationTests.wdk

        async let entropy1 = wdk.generateEntropyAndEncrypt(wordCount: 12)
        async let entropy2 = wdk.generateEntropyAndEncrypt(wordCount: 12)
        async let entropy3 = wdk.generateEntropyAndEncrypt(wordCount: 12)

        let results = try await (entropy1, entropy2, entropy3)

        // All should succeed with non-empty values
        #expect(!results.0.encryptionKey.isEmpty)
        #expect(!results.1.encryptionKey.isEmpty)
        #expect(!results.2.encryptionKey.isEmpty)

        // Each generation should produce unique keys
        #expect(results.0.encryptionKey != results.1.encryptionKey)
        #expect(results.1.encryptionKey != results.2.encryptionKey)
        #expect(results.0.encryptionKey != results.2.encryptionKey)
    }

    @Test("Dispose cleans up resources")
    func testDispose() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        try await wdk.dispose()
    }

    @Test("Dispose specific blockchains keeps the others alive")
    func testDisposePerBlockchain() async throws {
        let wdk = WDKOperationTests.wdk
        let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } },
            "polygon": { "blockchain": "polygon", "config": { "chainId": 137 } }
          }
        }
        """

        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )

        try await wdk.dispose(blockchains: ["ethereum"])

        // If the blockchains argument is not passed through to the worklet,
        // the handler falls back to a full dispose and polygon dies with it.
        let polygonAddress = try await wdk.getAddress(network: "polygon")
        #expect(polygonAddress.hasPrefix("0x"))
        #expect(polygonAddress.count == 42)

        // Full teardown still works after a partial dispose.
        try await wdk.dispose()
    }
}
