# js: the worklet toolchain

This directory is the one place where the JavaScript side of `WdkCore` is pinned and built. It produces the three things an app needs next to the Swift package:

| Output | Built from |
| ------ | ---------- |
| Worklet bundle (`wdk-worklet.mobile.bundle` on iOS, `wdk-worklet.macos.bundle` on macOS) | your `wdk.config.js`, with [`@tetherto/wdk-worklet-bundler`](https://github.com/tetherto/wdk-worklet-bundler) |
| Native addon frameworks, plus `addons.yml` on iOS | the native dependencies of the wallet packages you configured |
| `BareKit.xcframework` | a [BareKit](https://github.com/holepunchto/bare-kit/releases) 2.x release |

You rarely run anything here by hand. An app calls `scripts/bootstrap-app.sh` from its XcodeGen `preGenCommand` (see the [Integration Guide](../README.md#integration-guide)), and this repository's tests call it from `Scripts/test-with-frameworks.sh`.

## Files

| File | Purpose |
| ---- | ------- |
| `package.json`, `package-lock.json` | The pinned toolchain: bundler, worklet, wallet packages. See [Pinned dependencies](#pinned-dependencies). |
| `wdk.config.macos.js` | Worklet configuration of this repository's macOS test suite. |
| `scripts/bootstrap-app.sh` | Builds the bundle and the addons for a configuration and places them, with BareKit, in an app. `--help` lists the options. |
| `scripts/fetch-barekit.sh` | Provisions `BareKit.xcframework` from a BareKit 2.x release. Called by the bootstrap. |

## What a run does

`bootstrap-app.sh --platform <ios|macos> --app-root <dir>`:

1. Checks BareKit first: fetches `BareKit.xcframework` into `<dir>/frameworks`, or confirms the one already there is a BareKit 2.x framework. A 3.x tag or framework stops the run here.
2. Installs the pinned toolchain (`npm install`).
3. Copies your `wdk.config.js` into this directory, because the bundler resolves wallet packages next to the configuration file, and runs `wdk-worklet-bundler generate --transport jsonrpc --install`.
4. Moves the bundle to `<dir>/wdk-worklet.mobile.bundle` and the addons (with `addons.yml` on iOS) to `<dir>/addons`, and leaves this directory as it found it.

Things worth knowing:

- **Repeat runs are instant and work offline.** Nothing is rebuilt while the configuration, the pinned toolchain, the engine, the BareKit release and the destinations are unchanged and the outputs are still in place. `WDK_REFRESH=1` skips that check.
- **Only what the script installed is replaced.** It records the addons it put in `addons/` and removes exactly those on the next run. A `BareKit.xcframework` you placed yourself is used as it is, as long as it is a 2.x framework.
- **The BareKit archive is cached.** A release archive is about 400 MB and holds every platform, so it is kept in `~/Library/Caches/wdk-core-swift`. Delete that directory to force a new download.
- **One build at a time per checkout.** Two apps that share one checkout of this repository wait for each other.

## The worklet configuration

```js
module.exports = {
  transport: 'jsonrpc',

  networks: {
    ethereum: { package: '@tetherto/wdk-wallet-evm' },
    bitcoin: { package: '@tetherto/wdk-wallet-btc' }
  },

  options: {
    targets: ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator'],
    swiftTarget: 'MyApp',
    convertEsmToCjs: true // keep true: harmless on V8, required by any CJS-only engine (JSC, QuickJS)
  }
}
```

| Field | Meaning |
| ----- | ------- |
| `transport` | Always `'jsonrpc'`: it is the transport this line of `WdkCore` speaks. |
| `networks` | The key is the blockchain identifier you use at runtime (`initializeWDK`, `getAddress(network:)`). `package` is the wallet module that serves it. |
| `options.targets` | The hosts to build for. iOS: `ios-arm64`, `ios-arm64-simulator`, `ios-x64-simulator`. macOS: `darwin-arm64`, `darwin-x64`. |
| `options.swiftTarget` | iOS only. The Xcode target that embeds the addons; it is written into `addons.yml`. |
| `options.convertEsmToCjs` | See below. |

There is no `output` section: the bundler writes to its default locations inside this directory and the bootstrap moves the results into the app. A configuration with an `output` section fails the run.

A wallet package that is not in `package.json` is installed on the fly, at its latest version, by the bundler's `--install`. To pin it, add it to `package.json` in your fork.

### `convertEsmToCjs`: why it stays `true`

`convertEsmToCjs: true` makes the bundler run esbuild over the bundle's `.js`/`.mjs`/`.cjs` files and emit CommonJS. V8 runs that bundle as it is, and it is the only form a CJS-only engine can run, so the same bundle works everywhere. Leave it `true`, and do not remove it to work around a bundle validation error: those come from dependency drift, see [Pinned dependencies](#pinned-dependencies).

## Engine

**V8.** It is the engine of the BareKit 2.x prebuilds this package is built and tested with (BareKit 2.5.5). BareKit 3.x is a different distribution: it publishes no `prebuilds.zip`, has no Objective-C API, and needs [bare-stow](https://github.com/holepunchto/bare-stow). It is adopted in phase 3a of [tetherto/wdk-worklet-bundler#84](https://github.com/tetherto/wdk-worklet-bundler/issues/84), so 3.x tags and frameworks are rejected here.

### JavaScriptCore

V8 is the default, and the engine this package is tested and released with. The BareKit 2.x releases also ship JavaScriptCore builds (`ios-javascriptcore/`, `darwin-javascriptcore/`), and the setup supports them through one switch: change one word on the bootstrap line of your `project.yml`.

```
"$bootstrap" --platform ios --app-root "$PWD" --engine javascriptcore "$@"
```

`convertEsmToCjs` must be `true`: JavaScriptCore cannot load ES modules from the bundle, and the bootstrap refuses to continue otherwise.

JavaScriptCore is discouraged, and the team that enables it owns the engine issues. Known issues:

- **Intermittent crash on iOS 26.** The worklet can crash within the first second inside the system JavaScriptCore (`JSRopeString::resolveToBuffer`), see [#22](https://github.com/tetherto/wdk-core-swift/issues/22). Seen on BareKit 2.3.0 and 2.5.5.
- **A worklet started from plain JavaScript source aborts** on the JavaScriptCore build of BareKit 2.5.5, see [#20](https://github.com/tetherto/wdk-core-swift/issues/20). Start a packed bundle, which is what `WdkCore` always does.

Last checked on 2026-11-13 with BareKit 2.5.5. This repository's macOS suite passes on JavaScriptCore (run with `--engine javascriptcore` added to the bootstrap line of `Scripts/test-with-frameworks.sh`). On the iOS simulator the worklet answered in 9 of 9 launches on iOS 26.0, 12 of 12 on iOS 26.5 and 18 of 21 on iOS 26.3.1.

We recommend V8 until bare-stow manages the engine and phase 3a lands.

## Pinned dependencies

[`package.json`](./package.json) pins exact versions on purpose, and `package-lock.json` is committed so a fresh clone resolves the same tree. Do not "upgrade" these without running `./Scripts/test-with-frameworks.sh` and the app on a device.

- **`@tetherto/wdk-worklet-bundler` and `@tetherto/pear-wrk-wdk` at exactly `1.0.0-beta.17`.** These are the last releases of the JSON-RPC line. Later releases move to bare-stow and drop the JSON-RPC transport this package speaks, so a newer version would break the build or the worklet at boot.
- **`bare-node-runtime` at exactly `1.5.0`, as a dependency and as an override.** From 1.5.1 the runtime's globals eagerly load `bare-worker/global` (`BroadcastChannel`, `MessageChannel`), which pulls in a newer module stack than BareKit 2.x embeds. The pin is required on this BareKit line, V8 included: without it the process aborts as soon as the worklet bundle loads (verified with BareKit 2.5.5 on V8; the Android side sees the same as `ModuleTraverseError: ADDON_NOT_FOUND`). The wallet packages declare `bare-node-runtime ^1.5.2` but run on 1.5.0: the full suite passes. It is listed twice because the bundler requires the package at the top level, and npm only accepts an override of a direct dependency when both name the same version.
- **Wallet packages at exact versions.** `@tetherto/wdk`, `-wallet-evm`, `-wallet-evm-erc-4337`, `-wallet-btc` and `-wallet-solana` are the versions the suite and the starter app were validated with.
- **`bare-crypto` 1.13.7 or later and `bare-tls` 3.1.4 or later.** Earlier versions crash the process when their addons unload at worklet teardown. `bare-crypto` is pinned directly; `bare-tls` comes in through the wallet packages and the lockfile holds it above that floor.
