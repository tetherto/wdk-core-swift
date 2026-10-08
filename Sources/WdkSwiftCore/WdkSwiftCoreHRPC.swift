// Copyright 2026 Tether Operations Limited
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
import Foundation
import BareKit
import BareRPC
import HRPC
import Schema

/// Swift client for WDK operations via HRPC (bare-rpc + hyperschema encoding).
///
/// Same public surface as ``WdkSwiftCore`` but backed by the generated typed
/// HRPC peer instead of hand-rolled JSON-RPC framing. bare-rpc owns framing
/// and request multiplexing, so this class only bridges the worklet IPC pipe
/// to the peer and maps generated types to the existing WDK result types.
public class WdkSwiftCoreHRPC {
    private let worklet: Worklet
    private var ipc: IPC?
    private var isWorkletStarted = false
    private let bundleName: String
    private let bundlePath: String?

    private var initializationTask: Task<Void, Error>?
    private let initLock = NSLock()

    private var peer: HRPC?
    private let transport = IPCTransport()

    /// Called for every `log` event the worklet emits (send-only HRPC command,
    /// not available over the JSON-RPC transport).
    public var onWorkletLog: ((String, String) -> Void)?

    /// Initialize WdkSwiftCoreHRPC
    /// - Parameters:
    ///   - bundleName: Name of the worklet bundle (default: platform-specific - "wdk-worklet.macos.hrpc" on macOS, "wdk-worklet.mobile.hrpc" on iOS)
    ///   - bundlePath: Optional explicit path to the bundle. If provided, this takes precedence over auto-detection.
    public init(bundleName: String? = nil, bundlePath: String? = nil) {
        self.worklet = Worklet()

        #if os(macOS)
        self.bundleName = bundleName ?? "wdk-worklet.macos.hrpc"
        #else
        self.bundleName = bundleName ?? "wdk-worklet.mobile.hrpc"
        #endif
        self.bundlePath = bundlePath
    }

    deinit {
        transport.finishWriter()
        if isWorkletStarted {
            worklet.terminate()
        }
    }

    private func getBundlePath() -> String? {
        if let explicitPath = bundlePath {
            return explicitPath
        }

        if let mainPath = Bundle.main.path(forResource: bundleName, ofType: "bundle") {
            return mainPath
        }

        #if os(macOS)
        let testPath = FileManager.default.currentDirectoryPath
            + "/Tests/Resources/macos/\(bundleName).bundle"
        if FileManager.default.fileExists(atPath: testPath) {
            return testPath
        }
        #endif

        return nil
    }

    /// Returns the shared initialization task, creating one if needed.
    /// Synchronous so that NSLock is never held across a suspension point.
    private func resolveInitTask() -> Task<Void, Error>? {
        initLock.lock()
        defer { initLock.unlock() }

        if isWorkletStarted { return nil }
        if let existing = initializationTask { return existing }

        let newTask = Task<Void, Error> {
            guard let fullPath = self.getBundlePath() else {
                throw WDKError.bundleNotFound("Bundle not found: \(self.bundleName)")
            }

            let bundleData = try Data(contentsOf: URL(fileURLWithPath: fullPath))
            self.worklet.start(filename: fullPath, source: bundleData)

            let ipc = IPC(worklet: self.worklet)
            self.ipc = ipc
            self.isWorkletStarted = true

            let peer = HRPC(delegate: self.transport)
            self.peer = peer

            peer.onLog { [weak self] request in
                let type: String
                switch request?.type {
                case .error: type = "error"
                case .debug: type = "debug"
                default: type = "info"
                }
                self?.onWorkletLog?(type, request?.data ?? "")
            }

            self.transport.startWriter(ipc: ipc)
            self.startReaderLoop(ipc: ipc, peer: peer)
        }
        initializationTask = newTask
        return newTask
    }

    private func ensureWorkletStarted() async throws {
        guard let task = resolveInitTask() else { return }
        try await task.value
    }

    /// Single persistent task pumping raw IPC chunks into the peer.
    /// bare-rpc reassembles partial frames internally, so no framing here.
    private func startReaderLoop(ipc: IPC, peer: HRPC) {
        Task { [weak self] in
            do {
                while let chunk = try await ipc.read() {
                    await peer.receive(chunk)
                }
                self?.transport.fail(WDKError.ipcError("Connection closed while reading"))
            } catch {
                self?.transport.fail(error)
            }
        }
    }

    private func requirePeer() async throws -> HRPC {
        try await ensureWorkletStarted()
        if let error = transport.failure { throw error }
        guard let peer = self.peer else {
            throw WDKError.ipcError("HRPC peer not initialized")
        }
        return peer
    }

    /// Maps remote HRPC errors onto the shared WDKError surface.
    private func mapError(_ error: Error) -> Error {
        if let remote = error as? RPCRemoteError {
            return WDKError.rpcError(code: remote.code, message: remote.message)
        }
        return error
    }

    // MARK: - Public API Methods

    /// Start the worklet
    public func workletStart() async throws {
        let peer = try await requirePeer()
        do {
            _ = try await peer.workletStart(WorkletStartRequest(config: "{}"))
        } catch { throw mapError(error) }
    }

    /// Generate entropy and encrypt it (for new wallet creation)
    public func generateEntropyAndEncrypt(wordCount: Int) async throws -> EntropyResult {
        let peer = try await requirePeer()
        do {
            let response = try await peer.generateEntropyAndEncrypt(
                GenerateEntropyAndEncryptRequest(wordCount: UInt(wordCount))
            )
            guard let encryptionKey = response.encryptionKey,
                  let encryptedSeedBuffer = response.encryptedSeedBuffer,
                  let encryptedEntropyBuffer = response.encryptedEntropyBuffer else {
                throw WDKError.invalidResponse("Invalid generateEntropyAndEncrypt response")
            }
            return EntropyResult(
                encryptionKey: encryptionKey,
                encryptedSeedBuffer: encryptedSeedBuffer,
                encryptedEntropyBuffer: encryptedEntropyBuffer
            )
        } catch { throw mapError(error) }
    }

    /// Get mnemonic from encrypted entropy
    public func getMnemonicFromEntropy(encryptedEntropy: String, encryptionKey: String) async throws -> String {
        let peer = try await requirePeer()
        do {
            let response = try await peer.getMnemonicFromEntropy(
                GetMnemonicFromEntropyRequest(encryptedEntropy: encryptedEntropy, encryptionKey: encryptionKey)
            )
            guard let mnemonic = response.mnemonic else {
                throw WDKError.invalidResponse("Invalid getMnemonicFromEntropy response")
            }
            return mnemonic
        } catch { throw mapError(error) }
    }

    /// Convert mnemonic phrase to encrypted seed and entropy
    public func getSeedAndEntropyFromMnemonic(mnemonic: String) async throws -> SeedAndEntropyResult {
        let peer = try await requirePeer()
        do {
            let response = try await peer.getSeedAndEntropyFromMnemonic(
                GetSeedAndEntropyFromMnemonicRequest(mnemonic: mnemonic)
            )
            guard let encryptionKey = response.encryptionKey,
                  let encryptedSeedBuffer = response.encryptedSeedBuffer,
                  let encryptedEntropyBuffer = response.encryptedEntropyBuffer else {
                throw WDKError.invalidResponse("Invalid getSeedAndEntropyFromMnemonic response")
            }
            return SeedAndEntropyResult(
                encryptionKey: encryptionKey,
                encryptedSeedBuffer: encryptedSeedBuffer,
                encryptedEntropyBuffer: encryptedEntropyBuffer
            )
        } catch { throw mapError(error) }
    }

    /// Initialize WDK with encrypted seed
    public func initializeWDK(encryptionKey: String, encryptedSeed: String, config: String) async throws {
        let peer = try await requirePeer()
        do {
            _ = try await peer.initializeWdk(
                InitializeWDKRequest(encryptionKey: encryptionKey, encryptedSeed: encryptedSeed, config: config)
            )
        } catch { throw mapError(error) }
    }

    /// Call any method on a WDK account
    /// - Returns: Result as Any (can be String, Number, Array, Dictionary, etc.)
    public func callMethod(
        methodName: String,
        network: String,
        accountIndex: Int = 0,
        args: String? = nil,
        options: String? = nil
    ) async throws -> Any {
        let peer = try await requirePeer()
        do {
            let response = try await peer.callMethod(CallMethodRequest(
                methodName: methodName,
                network: network,
                accountIndex: UInt(accountIndex),
                args: args,
                options: options
            ))
            // The worklet returns the value JSON-stringified (HRPC string fields).
            guard let raw = response.result,
                  let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw WDKError.invalidResponse("Invalid callMethod response")
            }
            return value
        } catch { throw mapError(error) }
    }

    /// Register additional wallet(s) to an already initialized WDK instance
    public func registerWallet(config: String) async throws -> [String] {
        let peer = try await requirePeer()
        do {
            let response = try await peer.registerWallet(RegisterWalletRequest(config: config))
            guard let blockchainsString = response.blockchains,
                  let data = blockchainsString.data(using: .utf8),
                  let blockchains = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                throw WDKError.invalidResponse("Invalid registerWallet response")
            }
            return blockchains
        } catch { throw mapError(error) }
    }

    /// Register protocol to an already initialized WDK instance
    public func registerProtocol(config: String) async throws {
        let peer = try await requirePeer()
        do {
            _ = try await peer.registerProtocol(RegisterProtocolRequest(config: config))
        } catch { throw mapError(error) }
    }

    /// Dispose the WDK instance.
    ///
    /// Note: over HRPC `dispose` is a send-only event and the schema's
    /// DisposeRequest carries no fields, so per-blockchain disposal
    /// (supported by the JSON-RPC transport) cannot be expressed yet.
    public func dispose() async throws {
        let peer = try await requirePeer()
        do {
            try await peer.dispose(DisposeRequest())
        } catch { throw mapError(error) }
    }

    // MARK: - Convenience Methods

    /// Get account address
    public func getAddress(network: String, accountIndex: Int = 0) async throws -> String {
        let result = try await callMethod(
            methodName: "getAddress",
            network: network,
            accountIndex: accountIndex
        )

        guard let address = result as? String else {
            throw WDKError.invalidResponse("Invalid address format")
        }

        return address
    }

    /// Get account balance
    public func getBalance(network: String, accountIndex: Int = 0) async throws -> String {
        let result = try await callMethod(
            methodName: "getBalance",
            network: network,
            accountIndex: accountIndex
        )

        guard let balance = result as? String else {
            throw WDKError.invalidResponse("Invalid balance format")
        }

        return balance
    }
}

// MARK: - IPC Transport

/// Bridges the generated HRPC peer to the BareKit worklet IPC pipe.
/// Outgoing frames are serialized through a FIFO writer task; incoming
/// bytes are pumped by the owner's reader loop into `peer.receive`.
private final class IPCTransport: RPCDelegate {
    private var writeContinuation: AsyncStream<Data>.Continuation?
    private(set) var failure: Error?

    func startWriter(ipc: IPC) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.writeContinuation = continuation

        Task {
            for await frame in stream {
                do {
                    try await ipc.write(data: frame)
                } catch {
                    self.fail(error)
                    break
                }
            }
        }
    }

    func finishWriter() {
        writeContinuation?.finish()
    }

    func fail(_ error: Error) {
        if failure == nil { failure = error }
        writeContinuation?.finish()
    }

    func rpc(_ rpc: RPC, send data: Data) {
        writeContinuation?.yield(data)
    }

    func rpc(_ rpc: RPC, didFailWith error: Error) {
        fail(error)
    }
}
