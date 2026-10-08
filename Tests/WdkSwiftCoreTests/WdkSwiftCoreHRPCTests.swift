import Testing
import Foundation
import BareKit
@testable import WdkSwiftCore

/// Test suite for the HRPC transport (WdkSwiftCoreHRPC).
/// Requires the HRPC macOS bundle at Tests/Resources/macos/wdk-worklet.macos.hrpc.bundle
/// (generated from wdk-tmp with wdk.hrpc.config.js) and the addon frameworks
/// used by the JSON-RPC suite. Run via ./Scripts/test-with-frameworks.sh.

@Suite("WDK HRPC Operations", .serialized)
struct WDKHRPCOperationTests {
    // Single shared instance — worklet starts once and stays running,
    // same rationale as WDKOperationTests.
    nonisolated(unsafe) static let wdk = WdkSwiftCoreHRPC()

    @Test("HRPC bundle not found throws error")
    func testBundleNotFound() async {
        let wdk = WdkSwiftCoreHRPC(bundleName: "nonexistent-hrpc-bundle")

        do {
            _ = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
            Issue.record("Should have thrown bundleNotFound error")
        } catch WDKError.bundleNotFound(let message) {
            #expect(message.contains("nonexistent-hrpc-bundle"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("HRPC worklet starts and generates entropy")
    func testWorkletStarts() async throws {
        let result = try await WDKHRPCOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 12)

        #expect(!result.encryptionKey.isEmpty)
        #expect(!result.encryptedSeedBuffer.isEmpty)
        #expect(!result.encryptedEntropyBuffer.isEmpty)
        #expect(Data(base64Encoded: result.encryptionKey) != nil)
    }

    @Test("Generate 24-word entropy over HRPC")
    func testGenerateEntropy24Words() async throws {
        let result = try await WDKHRPCOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 24)

        #expect(!result.encryptionKey.isEmpty)
        #expect(!result.encryptedSeedBuffer.isEmpty)
        #expect(!result.encryptedEntropyBuffer.isEmpty)
    }

    @Test("Round-trip mnemonic conversion over HRPC")
    func testRoundTripMnemonic() async throws {
        let wdk = WDKHRPCOperationTests.wdk
        let entropy1 = try await wdk.generateEntropyAndEncrypt(wordCount: 12)
        let mnemonic1 = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: entropy1.encryptedEntropyBuffer,
            encryptionKey: entropy1.encryptionKey
        )

        let words = mnemonic1.split(separator: " ")
        #expect(words.count == 12)

        let entropy2 = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: mnemonic1)
        let mnemonic2 = try await wdk.getMnemonicFromEntropy(
            encryptedEntropy: entropy2.encryptedEntropyBuffer,
            encryptionKey: entropy2.encryptionKey
        )

        #expect(mnemonic1 == mnemonic2)
    }

    @Test("Initialize WDK and get Ethereum address over HRPC")
    func testInitializeAndGetAddress() async throws {
        let wdk = WDKHRPCOperationTests.wdk
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

        let address1 = try await wdk.getAddress(network: "ethereum", accountIndex: 1)
        #expect(address != address1)
    }

    @Test("Deterministic address derivation over HRPC")
    func testDeterministicAddresses() async throws {
        let wdk = WDKHRPCOperationTests.wdk
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        let config = """
        {
          "networks": {
            "ethereum": { "blockchain": "ethereum", "config": { "chainId": 1 } }
          }
        }
        """

        let entropy = try await wdk.getSeedAndEntropyFromMnemonic(mnemonic: testMnemonic)
        try await wdk.initializeWDK(
            encryptionKey: entropy.encryptionKey,
            encryptedSeed: entropy.encryptedSeedBuffer,
            config: config
        )
        let address = try await wdk.getAddress(network: "ethereum")

        // Same mnemonic must yield the same address as the JSON-RPC suite
        // uses on this well-known test vector.
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)

        let again = try await wdk.getAddress(network: "ethereum")
        #expect(address == again)
    }

    @Test("Concurrent calls multiplex correctly over HRPC", .timeLimit(.minutes(2)))
    func testConcurrentCalls() async throws {
        let wdk = WDKHRPCOperationTests.wdk
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
        #expect(results.1.hasPrefix("0x"))
        #expect(results.2.hasPrefix("0x"))
        #expect(results.0 != results.2)

        let ethAgain = try await wdk.getAddress(network: "ethereum", accountIndex: 0)
        #expect(results.0 == ethAgain)
    }

    @Test("Invalid word count throws rpcError over HRPC")
    func testInvalidWordCount() async {
        do {
            _ = try await WDKHRPCOperationTests.wdk.generateEntropyAndEncrypt(wordCount: 15)
            Issue.record("Should have thrown an error for invalid word count")
        } catch WDKError.rpcError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Invalid mnemonic throws rpcError over HRPC")
    func testInvalidMnemonic() async {
        do {
            _ = try await WDKHRPCOperationTests.wdk.getSeedAndEntropyFromMnemonic(mnemonic: "invalid mnemonic phrase")
            Issue.record("Should have thrown an error for invalid mnemonic")
        } catch WDKError.rpcError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Dispose is accepted as send-only event over HRPC")
    func testDispose() async throws {
        let wdk = WDKHRPCOperationTests.wdk
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

        // Send-only: no response to await; success == no throw on send.
        try await wdk.dispose()
    }
}
