/**
 * Worklet configuration for this repository's macOS test suite.
 *
 * Scripts/test-with-frameworks.sh builds it through scripts/bootstrap-app.sh. It has no
 * `output` section on purpose: the bundler writes to its default locations inside this
 * directory and the bootstrap script moves the results under Tests/Resources/macos/.
 *
 * A network name is the blockchain identifier the worklet expects at runtime.
 */
module.exports = {
  transport: 'jsonrpc',

  networks: {
    ethereum: { package: '@tetherto/wdk-wallet-evm' },
    polygon: { package: '@tetherto/wdk-wallet-evm' }
  },

  options: {
    targets: ['darwin-arm64', 'darwin-x64'],
    convertEsmToCjs: true // keep true: harmless on V8, required by any CJS-only engine (JSC, QuickJS)
  }
}
