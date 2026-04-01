import Testing
import Foundation
import BareKit
@testable import WdkSwiftCore

/// Test suite for WdkSwiftCore functionality
/// These tests require a macOS bundle to be generated first using:
/// ./Scripts/generate-macos-bundle.sh

// MARK: - IPC Tests

@Test("IPC echo with simple JS", .timeLimit(.minutes(1)))
func testIPCEchoSimple() async throws {
    let worklet = Worklet()

    let source = "BareKit.IPC.on('data', (data) => BareKit.IPC.write(data)).write(Buffer.from('READY'))"
    worklet.start(filename: "/echo.js", source: source.data(using: .utf8)!)

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

    let js = "BareKit.IPC.write(Buffer.from('HELLO_FROM_MODULE'))"
    worklet.start(filename: "/hello.js", source: js.data(using: .utf8)!)

    let ipc = IPC(worklet: worklet)

    let data = try await ipc.read()
    let msg = data.flatMap { String(data: $0, encoding: .utf8) }

    worklet.terminate()
    #expect(msg == "HELLO_FROM_MODULE")
}

@Test("FramedEcho", .timeLimit(.minutes(1)))
func testFramedEcho() async throws {
    let worklet = Worklet()

    let js = """
    const ipc = BareKit.IPC
    let buf = Buffer.alloc(0)
    ipc.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk])
      while (buf.length >= 4) {
        const len = buf.readUInt32BE(0)
        if (buf.length < 4 + len) break
        const msg = buf.slice(4, 4 + len)
        buf = buf.slice(4 + len)
        const header = Buffer.allocUnsafe(4)
        header.writeUInt32BE(msg.length, 0)
        ipc.write(Buffer.concat([header, msg]))
      }
    })
    ipc.write(Buffer.from('READY'))
    """

    worklet.start(filename: "/framed-echo.js", source: js.data(using: .utf8)!)
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
    let wdk = WdkSwiftCore(bundleName: "nonexistent-bundle")

    do {
        _ = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        Issue.record("Should have thrown bundleNotFound error")
    } catch WDKError.bundleNotFound(let message) {
        #expect(message.contains("nonexistent-bundle"))
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

// MARK: - Standalone WDK Test

@Test("Minimal WDK bundle load", .timeLimit(.minutes(1)))
func testMinimalWDKBundleLoad() async throws {
    let wdk = WdkSwiftCore()
    let result = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
    #expect(!result.encryptionKey.isEmpty)
}

// MARK: - WDK Operations (shared worklet to avoid crash on re-creation)

@Suite("WDK Operations", .serialized)
struct WDKOperationTests {
    // Single shared instance — worklet starts once and stays running.
    // Creating/destroying multiple WDK worklets causes SIGSEGV due to
    // async addon cleanup in the bare runtime.
    nonisolated(unsafe) static let wdk = WdkSwiftCore()

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
        let wdk = WdkSwiftCore(bundlePath: testPath)
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
            "polygon": { "blockchain": "ethereum", "config": { "chainId": 137 } }
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
              "config": { "chainId": 1, "rpcUrl": "https://eth.llamarpc.com" }
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
            "polygon": { "blockchain": "ethereum", "config": { "chainId": 137 } }
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
}
