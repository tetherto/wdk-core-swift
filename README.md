# WdkSwiftCore

A Swift Package for the [Tether WDK](https://github.com/Tetherto/wdk) (Wallet Development Kit). Provides a clean async/await API for wallet operations, key management, and multi-chain interactions on iOS and macOS.

Supported networks: EVM (Ethereum, Polygon, Arbitrum, Sepolia, etc.), Bitcoin, Solana, and ERC-4337.

## Integration Guide

### Step 1 — Add the SPM Package

Add this repository as a Swift Package dependency:

- **Xcode IDE:** **File > Add Package Dependencies** and enter this repository URL.
- **XcodeGen / command line:** declare it under `packages:` in your `project.yml` (see the [Example](#example) below).

This gives you the `WdkSwiftCore` Swift API.

### Step 2 — Obtain the Runtime Artifacts

You need three things alongside `WdkSwiftCore`:

| Artifact                      | What it is                                                              |
| ----------------------------- | ----------------------------------------------------------------------- |
| **BareKit.xcframework**       | The Bare runtime that hosts the JavaScript worklet                      |
| **Worklet bundle**            | `wdk-worklet.mobile.bundle` (iOS) or `wdk-worklet.macos.bundle` (macOS) |
| **Native addon xcframeworks** | One xcframework per native dependency (crypto, networking, filesystem, etc.) |

Generate them with the bundler as described below.

---

#### WDK Worklet Bundler

Use the [`wdk-worklet-bundler`](https://github.com/tetherto/wdk-worklet-bundler) CLI to generate the worklet bundle, link native addons, and produce an `addons.yml` — all in one step.

1. Install the bundler:

```bash
npm install -g @tetherto/wdk-worklet-bundler
```

2. Create a `wdk.config.js` in a working directory:

```js
module.exports = {
  transport: "jsonrpc",
  networks: {
    ethereum: { package: "@tetherto/wdk-wallet-evm" },
    bitcoin: { package: "@tetherto/wdk-wallet-btc" },
  },
  options: {
    platforms: ["ios"], // or ["ios", "macos"]
    // Required for iOS/macOS: JavaScriptCore cannot load ES modules from the
    // bundle. Without this the worklet aborts on the first ESM dependency.
    convertEsmToCjs: true,
  },
  output: {
    bundle: "./.wdk-bundle/wdk-worklet.mobile.bundle",
  },
};
```

3. Generate:

```bash
wdk-worklet-bundler generate --install
```

This produces:

- The worklet bundle at the configured output path
- Native addon xcframeworks in `ios-addons/` (or `mac-addons/`)
- An `addons.yml` for BareKit/XcodeGen integration

The set of addons is not fixed: the bundler links one xcframework per native dependency pulled in by the wallet and protocol packages in your `wdk.config.js`, so the count varies with the networks you enable.

4. Download **BareKit.xcframework** from [bare-kit releases](https://github.com/holepunchto/bare-kit/releases).

5. Continue to **Step 3** below to add everything to your project.

> See the [bundler README](https://github.com/tetherto/wdk-worklet-bundler#quick-start--swift--kotlin-json-rpc) for the full configuration reference and advanced options.

---

#### Pre-built releases (not available)

An earlier, naive attempt shipped pre-built worklet bundles and addon zips as GitHub prereleases. Those artifacts went stale against the current worklet and are no longer compatible, so generating the bundle with the bundler is currently the only supported path. Automating this so integration is as simple as [`wdk-core-kotlin`](https://github.com/Tetherto/wdk-core-kotlin) is tracked in [tetherto/wdk-core-swift#5](https://github.com/tetherto/wdk-core-swift/issues/5).

---

### Step 3 — Add to Your Project

You can wire the artifacts in from the Xcode IDE, or drive everything from the terminal with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and the Xcode Command Line Tools. Both produce the same result.

#### Using the Xcode IDE

1. **BareKit.xcframework** — Drag into your Xcode project. In your target's **General > Frameworks, Libraries, and Embedded Content**, set it to **Embed & Sign**.

2. **Worklet bundle** (`wdk-worklet.mobile.bundle` or `wdk-worklet.macos.bundle`) — Drag into your Xcode project navigator. Ensure it appears in your target's **Build Phases > Copy Bundle Resources**.

3. **Addon xcframeworks** — Drag all xcframeworks into your project. Add them to **Frameworks, Libraries, and Embedded Content** with **Embed & Sign**.

Build and run.

#### Using XcodeGen and the command line (no Xcode IDE required)

The `ios-addons/addons.yml` produced by the bundler is an XcodeGen fragment that declares every addon xcframework. XcodeGen resolves the framework paths in it relative to that file, so you can include the bundler output directory as-is. Add `BareKit.xcframework` and the worklet bundle, and let XcodeGen generate the project:

```yaml
include:
  - ios-addons/addons.yml

packages:
  WdkSwiftCore:
    url: https://github.com/tetherto/wdk-core-swift
    branch: main

targets:
  MyApp:
    type: application
    platform: iOS
    dependencies:
      - framework: frameworks/BareKit.xcframework
      - package: WdkSwiftCore
        product: WdkSwiftCore
    sources:
      - path: MyApp
      - path: wdk-worklet.mobile.bundle
        buildPhase: resources
```

Then build from any editor or terminal:

```bash
xcodegen generate
xcodebuild build -project MyApp.xcodeproj -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  CODE_SIGNING_ALLOWED=NO
```

Include `OS=` (or use `id=<udid>`) in the destination when several simulators share a name, otherwise `xcodebuild` reports the destination as ambiguous.

> The target name in `addons.yml` defaults to `app`. If your target is named differently, set `options.swiftTarget` in `wdk.config.js` (bundler) or edit `addons.yml` to match.

> **Xcode 26:** the Command Line Tools ship the iOS SDK without the simulator platform. If `xcodebuild` fails with "Supported platforms for the buildables in the current scheme is empty", run `xcodebuild -downloadPlatform iOS` once (several GB).

## Example

[**wdk-starter-swift**](https://github.com/Tetherto/wdk-starter-swift) is a minimal iOS app that integrates `WdkSwiftCore` end to end: create or import a wallet, derive Ethereum (Sepolia) and Bitcoin addresses, fetch balances, call arbitrary WDK methods, and dispose.

It follows the XcodeGen flow described above, so it does not depend on the Xcode IDE. The project was developed and built using only the Xcode Command Line Tools and VS Code — `xcodegen generate` followed by `xcodebuild` for a simulator destination — and it can equally be opened in Xcode. That command-line path was last verified against this package's `main` with Xcode 26.6 and XcodeGen 2.44 (build, install, and a create-wallet / addresses / balances / dispose run on an iOS 26 simulator). Use it as a reference for the `project.yml` layout, the `addons.yml` include, and where the worklet bundle and `BareKit.xcframework` live in the tree.

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
        "ethereum": {
            "blockchain": "ethereum",
            "config": { "chainId": 1, "rpcUrl": "https://eth-mainnet.example.com" }
        }
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
// Default: auto-detects platform bundle
//   macOS → wdk-worklet.macos.bundle
//   iOS   → wdk-worklet.mobile.bundle
let wdk = WdkSwiftCore()

// Custom bundle name
let wdk = WdkSwiftCore(bundleName: "my-custom-worklet")

// Custom bundle path (for frameworks, test targets, or app extensions)
let wdk = WdkSwiftCore(bundlePath: "/path/to/wdk-worklet.mobile.bundle")
```

### Wallet Lifecycle

| Method                                                    | Description                                                                                          |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `workletStart()`                                          | Start the worklet explicitly (otherwise started automatically on first use)                          |
| `generateEntropyAndEncrypt(wordCount:)`                   | Generate a new mnemonic (12 or 24 words) and return encrypted entropy                                |
| `getMnemonicFromEntropy(encryptedEntropy:encryptionKey:)` | Decrypt entropy to get the mnemonic phrase                                                           |
| `getSeedAndEntropyFromMnemonic(mnemonic:)`                | Convert an existing mnemonic to encrypted seed + entropy                                             |
| `initializeWDK(encryptionKey:encryptedSeed:config:)`      | Initialize WDK with keys and network configuration                                                   |
| `dispose(blockchains:)`                                   | Clean up resources. Omit `blockchains` to tear down the whole instance, or pass names to release only those |

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
    case ipcError(String)
    case rpcError(code: String, message: String)
    case invalidResponse(String)
    case bundleNotFound(String)
}
```

## Architecture

```
Your App
  │
  ├── WdkSwiftCore (Swift, async/await API)
  │     │
  │     ├── JSON-RPC 2.0 over length-prefixed IPC
  │     │
  │     └── BareKit (Worklet + IPC)
  │           │
  │           ├── wdk-worklet.{mobile,macos}.bundle (JavaScript worklet)
  │           │
  │           └── native addon xcframeworks
  │                 (crypto, networking, filesystem, etc. — one per native dependency)
  │
  └── BareKit.xcframework (Bare runtime — from holepunchto/bare-kit)
```

## Running the Tests

The test suite runs on macOS against a real worklet bundle and the addon frameworks. Generate them with the bundler using `platforms: ["macos"]`, `convertEsmToCjs: true`, and `output.bundle: "./.wdk-bundle/wdk-worklet.macos.bundle"`, then place them where the tests expect:

```
Frameworks/BareKit.xcframework          # from bare-kit releases
Tests/Resources/macos/wdk-worklet.macos.bundle
Tests/Resources/macos/Frameworks/*.framework   # contents of mac-addons/
```

Then prepare the frameworks and run the suite:

```bash
./Scripts/prepare-macos-frameworks.sh   # fix rpaths, re-sign ad hoc, unquarantine BareKit
./Scripts/test-with-frameworks.sh    # wraps `swift test` with BareKit linked
```

The first script adds the rpaths sibling addons need to load each other and re-signs them (see [Troubleshooting](#troubleshooting)). It resolves paths relative to the repository root, so it can be called from anywhere. The second symlinks the addon frameworks into the working directory so the Bare runtime can `dlopen` them, and cleans up afterwards. All of these paths are git-ignored.

## Troubleshooting

**Xcode refuses the addon frameworks with a code signature error.** Frameworks copied or dragged out of the bundler output lose their signature, and `install_name_tool` invalidates it too. Re-sign them ad hoc:

```bash
# iOS xcframeworks in your app
find ios-addons -name '*.framework' -type d -exec codesign -s - --force {} \;

# macOS test frameworks in this repo
./Scripts/prepare-macos-frameworks.sh
```

**`BareKit.xcframework` is blocked by Gatekeeper.** Archives downloaded from GitHub releases carry the `com.apple.quarantine` attribute, which can make the linker or `dyld` reject the framework. Strip it:

```bash
xattr -dr com.apple.quarantine path/to/BareKit.xcframework
```

**Worklet fails to boot with a signal 6 abort.** Two common causes:

- An addon cannot `dlopen` a sibling. Check that every framework the bundle needs is present and, on macOS, that the rpath fix above has been applied.
- The bundle contains ES modules. The console shows `Uncaught (in promise) createModule@[native code]` with a `bare-module` stack ending in a `require` from the worklet, and the process aborts on the first call. JavaScriptCore cannot load ESM from the bundle; set `options.convertEsmToCjs: true` in `wdk.config.js` and regenerate.

## Requirements

- iOS 14.0+ / macOS 11.0+
- Swift 5.9+
- Xcode 15.0+ (the full IDE, or just the Command Line Tools plus [XcodeGen](https://github.com/yonaskolb/XcodeGen))

## License

Apache-2.0
