// HiveDesk site configuration.
//
// Contract addresses are filled in after the launch from the deployment handoff. Until then the site
// renders its "not configured" state. Any value may also be supplied as a URL query parameter
// (?vault=0x...&registry=0x...&tracker=0x...&oracle=0x...&token=0x...&rpc=https://...) so a pinned IPFS
// build can point at the live contracts without a rebuild.
window.HIVEDESK_CONFIG = {
  chainId: 1,
  // Public mainnet JSON-RPC used for reads. Viewers may override it in the page.
  rpcUrl: "https://ethereum-rpc.publicnode.com",
  explorer: "https://etherscan.io",
  contracts: {
    token: "",
    registry: "",
    vault: "",
    tracker: "",
    oracle: "",
  },
  // Must match DeploymentConfig.EPOCH_BLOCKS.
  epochBlocks: 7200,
  // Block the contracts were deployed in (epoch 0 start). Also read live from the tracker.
  startBlock: 0,
  // Event scans are chunked to stay under public RPC limits.
  logChunk: 50000,
};
