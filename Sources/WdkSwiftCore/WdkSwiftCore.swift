import Foundation
import BareKit

// MARK: - Pending Requests Actor

/// Thread-safe storage for in-flight JSON-RPC continuations, keyed by request ID.
/// The reader loop resolves/rejects entries; callers register before sending.
private actor PendingRequests {
    private var continuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    func register(id: Int, continuation: CheckedContinuation<[String: Any], Error>) {
        continuations[id] = continuation
    }

    func resolve(id: Int, with response: [String: Any]) {
        continuations.removeValue(forKey: id)?.resume(returning: response)
    }

    func reject(id: Int, with error: Error) {
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    func rejectAll(with error: Error) {
        for (_, continuation) in continuations {
            continuation.resume(throwing: error)
        }
        continuations.removeAll()
    }
}

// MARK: - WdkSwiftCore

/// Swift client for WDK operations via JSON-RPC 2.0
/// Handles worklet lifecycle and IPC communication internally.
/// Supports concurrent calls via ID-based response multiplexing.
public class WdkSwiftCore {
    private let worklet: Worklet
    private var ipc: IPC?
    private var requestId: Int = 0
    private let requestIdQueue = DispatchQueue(label: "com.wdk.requestId")
    private var isWorkletStarted = false
    private let bundleName: String
    private let bundlePath: String?

    private let pending = PendingRequests()
    private var readerLoopStarted = false

    // Read buffer for framing (owned exclusively by the reader loop)
    private var readBuffer = Data()

    // Write serialization via AsyncStream FIFO queue
    private var writeContinuation: AsyncStream<WriteRequest>.Continuation?
    private var writerLoopStarted = false

    private struct WriteRequest {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Initialize WdkSwiftCore
    /// - Parameters:
    ///   - bundleName: Name of the worklet bundle (default: platform-specific - "wdk-worklet.macos" on macOS, "wdk-worklet.mobile" on iOS)
    ///   - bundlePath: Optional explicit path to the bundle. If provided, this takes precedence over auto-detection.
    public init(bundleName: String? = nil, bundlePath: String? = nil) {
        self.worklet = Worklet()

        #if os(macOS)
        self.bundleName = bundleName ?? "wdk-worklet.macos"
        #else
        self.bundleName = bundleName ?? "wdk-worklet.mobile"
        #endif
        self.bundlePath = bundlePath
    }

    deinit {
        writeContinuation?.finish()
        if isWorkletStarted {
            worklet.terminate()
        }
    }

    /// Get the bundle path using 3-tier lookup:
    /// 1. Explicit bundlePath parameter (highest priority)
    /// 2. Auto-detect in Bundle.main (for consumer custom bundles)
    /// 3. Fallback to module/test bundles
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

    /// Ensures the worklet and IPC are initialized
    private func ensureWorkletStarted() async throws {
        guard !isWorkletStarted else { return }

        guard let fullPath = getBundlePath() else {
            throw WDKError.bundleNotFound("Bundle not found: \(bundleName)")
        }

        let bundleData = try Data(contentsOf: URL(fileURLWithPath: fullPath))
        worklet.start(filename: fullPath, source: bundleData)

        try await Task.sleep(nanoseconds: 500_000_000)

        self.ipc = IPC(worklet: worklet)
        isWorkletStarted = true

        startReaderLoop()
        startWriterLoop()
    }

    // MARK: - Private Helper Methods

    private func nextRequestId() -> Int {
        requestIdQueue.sync {
            requestId += 1
            return requestId
        }
    }

    // MARK: - Reader Loop

    /// Single persistent task that reads all incoming framed messages
    /// and dispatches each to the correct caller via the pending requests map.
    private func startReaderLoop() {
        guard !readerLoopStarted else { return }
        readerLoopStarted = true

        Task { [weak self] in
            guard let self = self else { return }
            do {
                while true {
                    let data = try await self.readFramed()

                    guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                          let id = obj["id"] as? Int else {
                        continue
                    }

                    await self.pending.resolve(id: id, with: obj)
                }
            } catch {
                await self.pending.rejectAll(with: error)
            }
        }
    }

    // MARK: - Writer Loop

    /// Single persistent task that serializes all outgoing writes through a FIFO queue.
    /// Prevents interleaved writes when multiple calls are in flight.
    private func startWriterLoop() {
        guard !writerLoopStarted else { return }
        writerLoopStarted = true

        let (stream, continuation) = AsyncStream<WriteRequest>.makeStream()
        self.writeContinuation = continuation

        Task { [weak self] in
            for await request in stream {
                guard let self = self, let ipc = self.ipc else {
                    request.continuation.resume(throwing: WDKError.ipcError("IPC not initialized"))
                    continue
                }
                do {
                    try await ipc.write(data: request.data)
                    request.continuation.resume()
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Framing Methods

    /// Write a length-prefixed framed message via the serialized writer queue.
    private func writeFramed(data: Data) async throws {
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let frame = lengthData + data

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuation?.yield(WriteRequest(data: frame, continuation: continuation))
        }
    }

    /// Read a length-prefixed framed message (only called from the reader loop)
    private func readFramed() async throws -> Data {
        let lengthData = try await readExactly(bytes: 4)
        let length = lengthData.withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        guard length > 0 && length < 10_000_000 else {
            throw WDKError.ipcError("Invalid message length: \(length)")
        }

        return try await readExactly(bytes: Int(length))
    }

    /// Read exactly N bytes, buffering as needed (only called from the reader loop)
    private func readExactly(bytes: Int) async throws -> Data {
        guard let ipc = self.ipc else {
            throw WDKError.ipcError("IPC not initialized")
        }

        while readBuffer.count < bytes {
            guard let chunk = try await ipc.read() else {
                throw WDKError.ipcError("Connection closed while reading")
            }
            readBuffer.append(chunk)
        }

        let result = readBuffer.prefix(bytes)
        readBuffer = readBuffer.dropFirst(bytes)
        return Data(result)
    }

    // MARK: - Core RPC Call

    /// Send a JSON-RPC request and await its response, matched by ID.
    /// Multiple concurrent calls are supported -- each gets its own response.
    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureWorkletStarted()

        let id = nextRequestId()

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])

        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.pending.register(id: id, continuation: continuation)

                do {
                    try await self.writeFramed(data: requestData)
                } catch {
                    await self.pending.reject(id: id, with: error)
                }
            }
        }

        if let error = response["error"] as? [String: Any] {
            let errorMessage = error["message"] as? String ?? "Unknown error"
            let errorCode = error["code"] as? String ?? "UNKNOWN"
            throw WDKError.rpcError(code: errorCode, message: errorMessage)
        }

        guard let result = response["result"] as? [String: Any] else {
            throw WDKError.invalidResponse("Missing result in response")
        }

        return result
    }

    // MARK: - Public API Methods

    /// Start the worklet
    /// Note: This is called automatically on first use, but can be called explicitly
    /// to ensure the worklet is initialized before other operations.
    public func workletStart() async throws {
        _ = try await call(method: "workletStart", params: [:])
    }

    /// Generate entropy and encrypt it (for new wallet creation)
    /// - Parameter wordCount: Number of words for mnemonic (12 or 24)
    /// - Returns: Encrypted entropy result
    public func generateEntropyAndEncrypt(wordCount: Int) async throws -> EntropyResult {
        let result = try await call(method: "generateEntropyAndEncrypt", params: [
            "wordCount": wordCount
        ])

        guard let encryptionKey = result["encryptionKey"] as? String,
              let encryptedSeedBuffer = result["encryptedSeedBuffer"] as? String,
              let encryptedEntropyBuffer = result["encryptedEntropyBuffer"] as? String else {
            throw WDKError.invalidResponse("Invalid generateEntropyAndEncrypt response")
        }

        return EntropyResult(
            encryptionKey: encryptionKey,
            encryptedSeedBuffer: encryptedSeedBuffer,
            encryptedEntropyBuffer: encryptedEntropyBuffer
        )
    }

    /// Get mnemonic from encrypted entropy
    /// - Parameters:
    ///   - encryptedEntropy: Base64-encoded encrypted entropy
    ///   - encryptionKey: Base64-encoded encryption key
    /// - Returns: Mnemonic phrase
    public func getMnemonicFromEntropy(encryptedEntropy: String, encryptionKey: String) async throws -> String {
        let result = try await call(method: "getMnemonicFromEntropy", params: [
            "encryptedEntropy": encryptedEntropy,
            "encryptionKey": encryptionKey
        ])

        guard let mnemonic = result["mnemonic"] as? String else {
            throw WDKError.invalidResponse("Invalid getMnemonicFromEntropy response")
        }

        return mnemonic
    }

    /// Convert mnemonic phrase to encrypted seed and entropy
    /// - Parameter mnemonic: BIP39 mnemonic phrase
    /// - Returns: Encrypted seed and entropy
    public func getSeedAndEntropyFromMnemonic(mnemonic: String) async throws -> SeedAndEntropyResult {
        let result = try await call(method: "getSeedAndEntropyFromMnemonic", params: [
            "mnemonic": mnemonic
        ])

        guard let encryptionKey = result["encryptionKey"] as? String,
              let encryptedSeedBuffer = result["encryptedSeedBuffer"] as? String,
              let encryptedEntropyBuffer = result["encryptedEntropyBuffer"] as? String else {
            throw WDKError.invalidResponse("Invalid getSeedAndEntropyFromMnemonic response")
        }

        return SeedAndEntropyResult(
            encryptionKey: encryptionKey,
            encryptedSeedBuffer: encryptedSeedBuffer,
            encryptedEntropyBuffer: encryptedEntropyBuffer
        )
    }

    /// Initialize WDK with encrypted seed
    /// - Parameters:
    ///   - encryptionKey: Base64-encoded encryption key
    ///   - encryptedSeed: Base64-encoded encrypted seed
    ///   - config: WDK configuration JSON string
    public func initializeWDK(encryptionKey: String, encryptedSeed: String, config: String) async throws {
        _ = try await call(method: "initializeWDK", params: [
            "encryptionKey": encryptionKey,
            "encryptedSeed": encryptedSeed,
            "config": config
        ])
    }

    /// Call any method on a WDK account
    /// - Parameters:
    ///   - methodName: The method name to call (e.g., "getAddress", "getBalance")
    ///   - network: Network name (e.g., "ethereum", "polygon")
    ///   - accountIndex: Account index (default: 0)
    ///   - args: Optional arguments as JSON string
    ///   - options: Optional options as JSON string
    /// - Returns: Result as Any (can be String, Number, Array, Dictionary, etc.)
    public func callMethod(
        methodName: String,
        network: String,
        accountIndex: Int = 0,
        args: String? = nil,
        options: String? = nil
    ) async throws -> Any {
        var params: [String: Any] = [
            "methodName": methodName,
            "network": network,
            "accountIndex": accountIndex
        ]

        if let args = args {
            params["args"] = args
        }

        if let options = options {
            params["options"] = options
        }

        let result = try await call(method: "callMethod", params: params)

        guard let methodResult = result["result"] else {
            throw WDKError.invalidResponse("Invalid callMethod response")
        }

        return methodResult
    }

    /// Register additional wallet(s) to an already initialized WDK instance
    /// - Parameter config: Wallet configuration JSON string
    public func registerWallet(config: String) async throws -> [String] {
        let result = try await call(method: "registerWallet", params: [
            "config": config
        ])

        guard let blockchainsString = result["blockchains"] as? String else {
            throw WDKError.invalidResponse("Invalid registerWallet response")
        }

        guard let data = blockchainsString.data(using: .utf8),
              let blockchains = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw WDKError.invalidResponse("Invalid blockchains format")
        }

        return blockchains
    }

    /// Register protocol to an already initialized WDK instance
    /// - Parameter config: Protocol configuration JSON string
    public func registerProtocol(config: String) async throws {
        _ = try await call(method: "registerProtocol", params: [
            "config": config
        ])
    }

    /// Dispose the WDK instance and clean up resources
    public func dispose() async throws {
        _ = try await call(method: "dispose", params: [:])
    }

    // MARK: - Convenience Methods

    /// Get account address
    /// - Parameters:
    ///   - network: Network name
    ///   - accountIndex: Account index
    /// - Returns: Account address
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
    /// - Parameters:
    ///   - network: Network name
    ///   - accountIndex: Account index
    /// - Returns: Balance as string
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
