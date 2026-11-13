# WdkCore

A Swift Package for the [Tether WDK](https://github.com/Tetherto/wdk) (Wallet Development Kit). Provides a clean async/await API for wallet operations, key management, and multi-chain interactions on iOS and macOS.

Supported networks: EVM (Ethereum, Polygon, Arbitrum, Sepolia, etc.), Bitcoin, Solana, and ERC-4337.

For the broader WDK ecosystem, see the [WDK documentation](https://docs.wdk.tether.io/).

> **Renamed from `WdkSwiftCore`.** The module, the library product and the main type are now `WdkCore`, matching [`wdk-core-kotlin`](https://github.com/Tetherto/wdk-core-kotlin). To migrate, change `import WdkSwiftCore` to `import WdkCore`, `WdkSwiftCore(...)` to `WdkCore(...)`, and the product name in your project to `WdkCore`. The repository and the package URL stay `wdk-core-swift`.

## Integration Guide

`WdkCore` is a Swift package plus three runtime artifacts that live in your app:

| Artifact                     | What it is                                                                   |
| ---------------------------- | ---------------------------------------------------------------------------- |
| **BareKit.xcframework**      | The Bare runtime that hosts the JavaScript worklet                           |
| **Worklet bundle**           | `wdk-worklet.mobile.bundle` (iOS) or `wdk-worklet.macos.bundle` (macOS)      |
| **Native addon frameworks**  | One framework per native dependency (crypto, networking, filesystem, etc.)   |

You describe your networks in one file, and `xcodegen generate` builds and wires everything else. The work is done by the pinned JavaScript workspace in this repository's [`js/`](js/README.md) directory, so the bundle, the addons and the Swift package always come from the same revision.

> **Supported stack.** BareKit **2.5.5** with the **V8** engine, `@tetherto/wdk-worklet-bundler` and `@tetherto/pear-wrk-wdk` **1.0.0-beta.17** (JSON-RPC transport), `bare-kit-swift` **1.x**. BareKit 2.5.5 is the latest BareKit this package supports. BareKit 3.x is a different distribution that needs [bare-stow](https://github.com/holepunchto/bare-stow) and arrives with the rework tracked in [tetherto/wdk-worklet-bundler#84](https://github.com/tetherto/wdk-worklet-bundler/issues/84); the setup refuses it. JavaScriptCore builds of BareKit 2.x are available through a documented switch. It is discouraged because of a known crash on iOS 26, see [`js/README.md`](js/README.md#javascriptcore).

You need [XcodeGen](https://github.com/yonaskolb/XcodeGen) on your `PATH` (`brew install xcodegen`), Node.js `^22.21.0` or `>=24.9.0` with npm, and git.

### Step 1: Describe your networks

Create `wdk.config.js` in the root of your app:

```js
module.exports = {
  transport: 'jsonrpc',

  // A network name is the blockchain identifier you pass to initializeWDK() and getAddress().
  networks: {
    ethereum: { package: '@tetherto/wdk-wallet-evm' },
    bitcoin: { package: '@tetherto/wdk-wallet-btc' }
  },

  options: {
    targets: ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator'],
    swiftTarget: 'MyApp', // the Xcode target that embeds the addons
    convertEsmToCjs: true // keep true: harmless on V8, required by any CJS-only engine (JSC, QuickJS)
  }
}
```

Do not add an `output` section: the setup decides where the results go. The wallet packages listed in [`js/package.json`](js/package.json) are pinned to tested versions. Any other package you name is installed on the fly at its latest version.

### Step 2: Wire it into `project.yml`

```yaml
# XcodeGen reads includes before it runs the preGenCommand that writes addons.yml, so the
# include is off in the first pass and on in the second pass the postGenCommand starts.
include:
  - path: addons/addons.yml
    enable: ${WDK_ADDONS_READY}

packages:
  WdkCore:
    url: https://github.com/tetherto/wdk-core-swift
    branch: main

options:
  # Builds the bundle, the addons and BareKit with the wdk-core-swift revision named above.
  preGenCommand: |
    [ "$WDK_INNER" = 1 ] && exit 0
    set -e
    core_field() {
      awk -v key="$1:" '
        /^  WdkCore:/ { inside = 1; next }
        inside && /^ ? ?[^ #]/ { inside = 0 }
        inside && $1 == key { sub(/^[^:]*:[ ]*/, ""); sub(/[ ]+#.*$/, ""); print; exit }
      ' project.yml | tr -d "\"'"
    }
    core_path=$(core_field path)
    if [ -n "$core_path" ]; then
      bootstrap="$core_path/js/scripts/bootstrap-app.sh"
      set --
    else
      core_url=$(core_field url)
      core_ref=""
      for key in branch revision exactVersion version; do
        [ -n "$core_ref" ] || core_ref=$(core_field "$key")
      done
      if [ -z "$core_url" ] || [ -z "$core_ref" ]; then
        echo "project.yml: packages.WdkCore needs 'path', or 'url' with 'branch', 'revision' or 'exactVersion'" >&2
        exit 1
      fi
      [ -d .wdk-core-swift/.git ] || git clone --quiet "$core_url" .wdk-core-swift
      git -C .wdk-core-swift remote set-url origin "$core_url"
      bootstrap=.wdk-core-swift/js/scripts/bootstrap-app.sh
      if [ ! -x "$bootstrap" ]; then
        # A clone starts on the default branch, which may not have the js/ workspace yet:
        # move it to the requested revision before looking for the script.
        git -C .wdk-core-swift fetch --quiet --tags origin
        for candidate in "origin/$core_ref" "$core_ref" "v$core_ref"; do
          git -C .wdk-core-swift checkout --quiet --detach "$candidate" 2>/dev/null && break
        done
      fi
      set -- --core-ref "$core_ref"
    fi
    if [ ! -x "$bootstrap" ]; then
      echo "project.yml: $bootstrap not found. This setup needs a wdk-core-swift revision that has the js/ workspace." >&2
      exit 1
    fi
    # The engine is the last word before "$@". V8 is the default and the tested one, see js/README.md.
    "$bootstrap" --platform ios --app-root "$PWD" --engine v8 "$@"
  # Second pass: generates the project again, this time with addons/addons.yml included.
  # If it fails, the project of the first pass (which has no addons) is removed.
  postGenCommand: |
    [ "$WDK_INNER" = 1 ] && exit 0
    WDK_INNER=1 WDK_ADDONS_READY=true xcodegen generate --quiet && exit 0
    code=$?
    rm -rf MyApp.xcodeproj
    exit $code

name: MyApp

targets:
  MyApp:
    type: application
    platform: iOS
    deploymentTarget: "15.0"
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.example.MyApp  # use your own
    dependencies:
      - framework: frameworks/BareKit.xcframework
      - package: WdkCore
        product: WdkCore
    sources:
      - path: MyApp
      - path: wdk-worklet.mobile.bundle
        buildPhase: resources
```

The setup reads the `WdkCore` entry under `packages`, so the revision is named once:

- `url` with `branch`, `revision` or `exactVersion`: a clone of that revision is kept in `.wdk-core-swift/` for its `js/` workspace. Xcode downloads the Swift package separately, as usual. A version range such as `from:` is not accepted, because it does not name one revision.
- `path`: a local checkout of this repository is used as it is. Handy when you work on both.

When you copy the two commands into your own project, three things must match it: the package key is `WdkCore`, indented by two spaces under `packages:`; the spec file is named `project.yml`; and the `rm -rf` line of the `postGenCommand` names your project. The commands are plain `sh` and avoid `${...}`, which XcodeGen would expand itself.

Add the generated files to your `.gitignore`:

```gitignore
*.xcodeproj
.wdk-core-swift/
addons/
frameworks/BareKit.xcframework
frameworks/.barekit-release
wdk-worklet.mobile.bundle
```

### Step 3: Generate and build

```bash
xcodegen generate
xcodebuild build -project MyApp.xcodeproj -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  CODE_SIGNING_ALLOWED=NO
```

The first `xcodegen generate` installs the JavaScript toolchain, builds the bundle and the addons for your `wdk.config.js`, and downloads the BareKit release (about 400 MB, once, kept in `~/Library/Caches/wdk-core-swift`). After that:

- Running it again is instant and works offline while nothing changed.
- Edit `wdk.config.js` and run it again to change networks. The addon set follows your networks: one framework per native dependency of the wallet packages you enabled.
- `WDK_REFRESH=1 xcodegen generate` rebuilds everything. With a `branch` it also moves the clone to the newest commit of that branch.
- Run plain `xcodegen generate` from the directory of `project.yml`. Options such as `--spec`, `--project` and `--use-cache` are not passed on to the second pass.

Include `OS=` (or use `id=<udid>`) in the `xcodebuild` destination when several simulators share a name, otherwise `xcodebuild` reports the destination as ambiguous.

> **Xcode 26 and later:** the Command Line Tools ship the iOS SDK without the simulator platform. If `xcodebuild` fails with "Supported platforms for the buildables in the current scheme is empty", run `xcodebuild -downloadPlatform iOS` once (several GB).

### Without XcodeGen

Clone this repository anywhere and run the same script by hand:

```bash
git clone https://github.com/tetherto/wdk-core-swift
wdk-core-swift/js/scripts/bootstrap-app.sh --platform ios --app-root /path/to/MyApp
```

It leaves `wdk-worklet.mobile.bundle`, `addons/` and `frameworks/BareKit.xcframework` in your app (`--help` lists the options, including `--platform macos`). Then, in the Xcode IDE:

1. **BareKit.xcframework**: drag it into your project. In your target's **General > Frameworks, Libraries, and Embedded Content**, set it to **Embed & Sign**.
2. **Worklet bundle**: drag it into the project navigator and make sure it appears in **Build Phases > Copy Bundle Resources**.
3. **Addon xcframeworks**: drag all of `addons/*.xcframework` into your project and set them to **Embed & Sign**.

Add this repository under **File > Add Package Dependencies** for the `WdkCore` Swift API, then build and run.

## Example

[**wdk-starter-swift**](https://github.com/Tetherto/wdk-starter-swift) is a minimal iOS app that integrates `WdkCore` end to end: create or import a wallet, derive Ethereum (Sepolia) and Bitcoin addresses, fetch balances, call arbitrary WDK methods, and dispose.

It follows the XcodeGen flow described above, so it does not depend on the Xcode IDE: `xcodegen generate` followed by `xcodebuild` for a simulator destination, and it can equally be opened in Xcode. Use it as a reference for `wdk.config.js`, the `project.yml` hooks, and where the worklet bundle and `BareKit.xcframework` live in the tree.

## Quick Start

```swift
import WdkCore

// Initialize
let wdk = WdkCore()

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
let wdk = WdkCore()

// Custom bundle name
let wdk = WdkCore(bundleName: "my-custom-worklet")

// Custom bundle path (for frameworks, test targets, or app extensions)
let wdk = WdkCore(bundlePath: "/path/to/wdk-worklet.mobile.bundle")
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
  ├── WdkCore (Swift, async/await API)
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

The test suite runs on macOS against a real worklet bundle and the addon frameworks. One command does everything from a clean checkout:

```bash
./Scripts/test-with-frameworks.sh
```

It builds the bundle and the addons for [`js/wdk.config.macos.js`](js/wdk.config.macos.js) and fetches BareKit (both through `js/scripts/bootstrap-app.sh`, which does nothing when they are up to date), fixes the addon rpaths and re-signs them (`Scripts/prepare-macos-frameworks.sh`, see [Troubleshooting](#troubleshooting)), packs the small fixture worklets of `Tests/Fixtures/` into bundles, and runs `swift test` with BareKit linked. Arguments are passed on to `swift test`, and `WDK_REFRESH=1` forces a rebuild. Plain `swift test` does not work: it cannot find BareKit.

The generated files are git-ignored:

```
Frameworks/BareKit.xcframework                  # BareKit 2.x, V8
Tests/Resources/macos/wdk-worklet.macos.bundle
Tests/Resources/macos/Frameworks/*.framework
Tests/Resources/macos/fixtures/*.bundle
```

While it runs, the test helper symlinks the addon frameworks into the working directory so the Bare runtime can `dlopen` them, and it owns the `bare-*.framework` and `sodium-*.framework` names in the repository root. It replaces existing links with those names and removes its temporary links afterwards. If you stage your own frameworks for testing, clean them up before running the helper.

## Troubleshooting

**`'BareKit/BareKit.h' file not found` when building.** The compiler did not find a BareKit 2.x framework. Either `frameworks/BareKit.xcframework` is missing, or it is a BareKit 3.x framework, which has no Objective-C API (it only ships `bare-kit.h`). Remove it and run `xcodegen generate` again to fetch the supported release. In this repository, run the tests through `./Scripts/test-with-frameworks.sh`.

**Swift errors about `Worklet` inside `WdkCore.swift`** (a call that can throw, or wrong argument labels on `start`). The build resolved `bare-kit-swift` 2.x, which wraps Bare Kit v3. This package requires 1.x and declares it in `Package.swift`. Remove any override of that dependency in your project, delete your `Package.resolved`, and resolve packages again.

**The setup refuses a BareKit release or framework.** Only BareKit 2.x release tags (`v2.<minor>.<patch>`) are accepted, and a framework found in `frameworks/` must expose the Bare Kit v2 API. See the supported stack at the top of the [Integration Guide](#integration-guide).

**Xcode refuses the addon frameworks with a code signature error.** Frameworks copied or dragged out of the bundler output lose their signature, and `install_name_tool` invalidates it too. Re-sign them ad hoc:

```bash
# iOS xcframeworks in your app
find addons -name '*.framework' -type d -exec codesign -s - --force {} \;

# macOS test frameworks in this repo
./Scripts/prepare-macos-frameworks.sh
```

**`BareKit.xcframework` is blocked by Gatekeeper.** Archives downloaded from GitHub releases carry the `com.apple.quarantine` attribute, which can make the linker or `dyld` reject the framework. The setup strips it. For a framework you downloaded yourself:

```bash
xattr -dr com.apple.quarantine path/to/BareKit.xcframework
```

**Worklet fails to boot with a signal 6 abort.** Common causes:

- An addon cannot `dlopen` a sibling. Check that every framework the bundle needs is present and, on macOS, that the rpath fix above has been applied.
- The `bare-node-runtime` pin was removed or raised. See the pinned dependencies in [`js/README.md`](js/README.md#pinned-dependencies).
- On JavaScriptCore only: the bundle contains ES modules. The console shows `Uncaught (in promise) createModule@[native code]` with a `bare-module` stack ending in a `require` from the worklet. Keep `options.convertEsmToCjs: true` in `wdk.config.js` and regenerate.

## Requirements

- iOS 14.0+ / macOS 13.0+
- Swift 5.10+ (Xcode 15.3+; the full IDE, or just the Command Line Tools plus [XcodeGen](https://github.com/yonaskolb/XcodeGen))
- For the setup: Node.js `^22.21.0` or `>=24.9.0` with npm, git, and XcodeGen 2.46+ on your `PATH`
- BareKit 2.5.5 (V8), fetched by the setup

## License

Apache-2.0
