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
