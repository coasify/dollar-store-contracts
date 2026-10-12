// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockStableERC20} from "./MockStableERC20.sol";

/// @title DeployMockStables - Deploys the mock stables for testnet (Sepolia)
/// @notice Deploys faucet ERC20s with public mint, matching the real assets' decimals: USDC and USDT
///         use 6, USDS uses 18 (real Sky USDS). Hub-and-spoke topology under rehearsal: the hub holds
///         USDC + USDS (poolId 0), and USDT is listed as the first spoke (poolId >= 1). For testnet
///         rehearsal only. The USDC/USDT mocks are already on-chain (see DEPLOYMENT.md); set the
///         DEPLOY_* flags below to redeploy only what is missing (USDS) instead of the whole set.
/// @dev Env vars:
///      - DEPLOYER_PRIVATE_KEY (required): broadcasting key.
///      - DEPLOY_USDC / DEPLOY_USDT (optional bool, default false): redeploy the hub/spoke mocks that
///        already exist. Leave false to reuse the documented addresses.
///      - DEPLOY_USDS (optional bool, default true): deploy the new hub USDS mock.
///      Run with `--broadcast --verify` to deploy and verify on Etherscan in one shot.
contract DeployMockStables is Script {
    // Real-asset decimals: USDC and USDT use 6 on Ethereum; Sky USDS uses 18.
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant USDT_DECIMALS = 6;
    uint8 internal constant USDS_DECIMALS = 18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bool deployUsdc = vm.envOr("DEPLOY_USDC", false);
        bool deployUsdt = vm.envOr("DEPLOY_USDT", false);
        bool deployUsds = vm.envOr("DEPLOY_USDS", true);

        vm.startBroadcast(deployerKey);

        if (deployUsdc) {
            MockStableERC20 usdc = new MockStableERC20("USD Coin (Mock)", "USDC", USDC_DECIMALS);
            console2.log("Mock USDC:", address(usdc));
            console2.log("  decimals:", usdc.decimals());
        }
        if (deployUsdt) {
            MockStableERC20 usdt = new MockStableERC20("Tether USD (Mock)", "USDT", USDT_DECIMALS);
            console2.log("Mock USDT:", address(usdt));
            console2.log("  decimals:", usdt.decimals());
        }
        if (deployUsds) {
            MockStableERC20 usds = new MockStableERC20("USDS (Mock)", "USDS", USDS_DECIMALS);
            console2.log("Mock USDS:", address(usds));
            console2.log("  decimals:", usds.decimals());
        }

        vm.stopBroadcast();
    }
}
