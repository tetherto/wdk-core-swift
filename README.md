# WdkSwiftCore

A Swift Package for the [Tether WDK](https://github.com/Tetherto/wdk) (Wallet Development Kit). Provides a clean async/await API for wallet operations, key management, and multi-chain interactions on iOS and macOS.

Supported networks: Ethereum, Polygon, Arbitrum, Sepolia, Solana, and ERC-4337.

## Integration Guide

### Step 1 -- Add the SPM Package

In Xcode: **File > Add Package Dependencies** and enter this repository URL.

This gives you the `WdkSwiftCore` Swift API.

### Step 2 -- Download Release Artifacts

Download `prebuilds.zip` and `addons.zip` from the [latest release](https://github.com/claudiovb/pear-wrk-wdk-jsonrpc/releases/latest).

| File            | Contents                                                                |
| --------------- | ----------------------------------------------------------------------- |
| `prebuilds.zip` | `BareKit.xcframework` (runtime) + `wdk-worklet.mobile.bundle` (worklet) |
| `addons.zip`    | 17 native addon xcframeworks required by the Bare runtime               |

### Step 3 -- Add to Xcode Project

1. **BareKit.xcframework** -- Drag into your Xcode project. In your target's **General > Frameworks, Libraries, and Embedded Content**, set it to **Embed & Sign**.

2. **wdk-worklet.mobile.bundle** -- Drag into your Xcode project navigator. Ensure it appears in your target's **Build Phases > Copy Bundle Resources**.

3. **17 addon xcframeworks** -- Drag all xcframeworks from the unzipped `addons.zip` into your project. Add them to **Frameworks, Libraries, and Embedded Content** with **Embed & Sign**.

   If using XcodeGen, an `addons.yml` is included in `addons.zip` that you can include in your `project.yml`.

Build and run.

## Quick Start

```swift
import WdkSwiftCore

// Initialize
let wdk = WdkSwiftCore()

// Create a new wallet
let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

// Show the mnemonic to the user for backup
let mnemonic = try await wdk.getMnemonicFromEntropy(
    encryptedEntropy: entropy.encryptedEntropyBuffer,
    encryptionKey: entropy.encryptionKey
)
print("Backup phrase: \(mnemonic)")

// Initialize WDK with network configuration
let config = """
{
    "networks": {
        "ethereum": { "rpcUrl": "https://eth-mainnet.example.com" }
    }
}
"""
try await wdk.initializeWDK(
    encryptionKey: entropy.encryptionKey,
    encryptedSeed: entropy.encryptedSeedBuffer,
    config: config
)

// Get an address
let address = try await wdk.getAddress(network: "ethereum")
print("Address: \(address)")

// Get balance
let balance = try await wdk.getBalance(network: "ethereum")
print("Balance: \(balance)")

// Clean up when done
try await wdk.dispose()
```

## API Reference

### Initialization

```swift
// Default: loads wdk-worklet.mobile.bundle from the app's main bundle
let wdk = WdkSwiftCore()

// Custom bundle name
let wdk = WdkSwiftCore(bundleName: "my-custom-worklet.mobile")

// Custom bundle path (for frameworks, test targets, or app extensions)
let wdk = WdkSwiftCore(bundlePath: "/path/to/wdk-worklet.mobile.bundle")
```

### Wallet Lifecycle

| Method                                                    | Description                                                           |
| --------------------------------------------------------- | --------------------------------------------------------------------- |
| `generateEntropyAndEncrypt(wordCount:)`                   | Generate a new mnemonic (12 or 24 words) and return encrypted entropy |
| `getMnemonicFromEntropy(encryptedEntropy:encryptionKey:)` | Decrypt entropy to get the mnemonic phrase                            |
| `getSeedAndEntropyFromMnemonic(mnemonic:)`                | Convert an existing mnemonic to encrypted seed + entropy              |
| `initializeWDK(encryptionKey:encryptedSeed:config:)`      | Initialize WDK with keys and network configuration                    |
| `dispose()`                                               | Clean up all resources                                                |

### Account Operations

| Method                                                      | Description                           |
| ----------------------------------------------------------- | ------------------------------------- |
| `getAddress(network:accountIndex:)`                         | Get the account address for a network |
| `getBalance(network:accountIndex:)`                         | Get the account balance for a network |
| `callMethod(methodName:network:accountIndex:args:options:)` | Call any WDK method on an account     |

### Dynamic Registration

| Method                      | Description                                 |
| --------------------------- | ------------------------------------------- |
| `registerWallet(config:)`   | Register additional wallet types at runtime |
| `registerProtocol(config:)` | Register additional protocols at runtime    |

## Error Handling

All methods throw `WDKError` with the following cases:

```swift
public enum WDKError: Error {
    case ipcError(String)           // Communication failure with the worklet
    case rpcError(code: String, message: String)  // Error returned by the WDK worklet
    case invalidResponse(String)    // Unexpected response format
    case bundleNotFound(String)     // Worklet bundle not found in the app
}
```

## Custom Worklet Bundle

If you need a custom worklet with different WDK modules or network configurations:

1. Clone the [pear-wrk-wdk-jsonrpc](https://github.com/claudiovb/pear-wrk-wdk-jsonrpc) repo
2. Modify `package.json` dependencies and `src/` as needed
3. Run `npm install && npm run build:bundle` to generate your custom bundle
4. Replace `wdk-worklet.mobile.bundle` in your Xcode project with your custom build

## Architecture

```
Your App
  |
  |-- WdkSwiftCore (Swift, async/await API)
  |     |
  |     |-- JSON-RPC 2.0 over length-prefixed IPC
  |     |
  |     '-- BareKit (Worklet + IPC)
  |           |
  |           |-- wdk-worklet.mobile.bundle (JavaScript worklet)
  |           |
  |           '-- 17 native addon xcframeworks
  |                 (crypto, networking, filesystem, etc.)
  |
  '-- BareKit.xcframework (Bare runtime)
```

## Requirements

- iOS 14.0+ / macOS 11.0+
- Swift 5.9+
- Xcode 15.0+

## License

Apache-2.0
