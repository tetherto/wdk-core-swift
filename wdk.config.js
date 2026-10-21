module.exports = {
  transport: "jsonrpc",
  networks: {
    ethereum: { package: "@tetherto/wdk-wallet-evm" },
    polygon:  { package: "@tetherto/wdk-wallet-evm" },
    bitcoin:  { package: "@tetherto/wdk-wallet-btc" },
  },
  output: {
    bundle: "./wdk-worklet.macos.bundle",
    addons: { ios: "./addons-ios-macrun", macos: "./mac-addons" },
    addonsYml: "./addons-ios-macrun/addons.yml",
  },
  options: {
    targets: ["ios-arm64", "ios-arm64-simulator", "ios-x64-simulator", "darwin-arm64", "darwin-x64"],
    swiftTarget: "wdk-starter-swift",
    convertEsmToCjs: true,
  },
};
