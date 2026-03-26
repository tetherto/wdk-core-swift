import Foundation

/// Result from entropy/seed generation and encryption
public struct EntropyResult: Sendable {
    public let encryptionKey: String
    public let encryptedSeedBuffer: String
    public let encryptedEntropyBuffer: String

    public init(encryptionKey: String, encryptedSeedBuffer: String, encryptedEntropyBuffer: String) {
        self.encryptionKey = encryptionKey
        self.encryptedSeedBuffer = encryptedSeedBuffer
        self.encryptedEntropyBuffer = encryptedEntropyBuffer
    }
}


public typealias SeedAndEntropyResult = EntropyResult
