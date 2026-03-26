import Foundation

/// Error types for WDK operations
public enum WDKError: Error {
    case ipcError(String)
    case rpcError(code: String, message: String)
    case invalidResponse(String)
    case bundleNotFound(String)
}

extension WDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ipcError(let message):
            return "IPC Error: \(message)"
        case .rpcError(let code, let message):
            return "RPC Error [\(code)]: \(message)"
        case .invalidResponse(let message):
            return "Invalid Response: \(message)"
        case .bundleNotFound(let message):
            return "Bundle Not Found: \(message)"
        }
    }
}
