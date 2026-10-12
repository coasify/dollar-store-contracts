// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DollarStore} from "../src/DollarStore.sol";

/// @title CreateSpoke - schedule/execute a `createSpoke` governor action through the governor timelock.
/// @notice `createSpoke` is governor-gated, and in production the governor is the governor
///         TimelockController (proposed by the governor Safe). This script builds the timelock
///         operation and either schedules it (proposer) or, after the delay, executes it (open
///         executor). In production the governor Safe schedules/executes via its own tooling; this
///         script is the reference/testnet path when the proposer key is an EOA.
/// @dev Env vars:
///      - DEPLOYER_PRIVATE_KEY (required): broadcasting key. For `schedule` it must hold PROPOSER on
///        the governor timelock; `execute` is open (executors = [address(0)]).
///      - STORE_PROXY (required): the DollarStore proxy address (the timelock's call target).
///      - GOVERNOR_TIMELOCK (required): the governor TimelockController address.
///      - SPOKE_ASSET (required): the challenger stablecoin to list as a spoke.
///      - SPOKE_FEED (required): its Chainlink price feed.
///      - SPOKE_MIN_DLRS (optional): initial protected minimum DLRS-side reserve (6dp). Default 0.
///      - SPOKE_LAUNCH_CAP (optional, 6dp): launch exposure cap for the new spoke. Default 0 (no cap).
///        When set, the operation becomes a BATCH of createSpoke + setLaunchCap, so the spoke can never
///        exist uncapped: both land in the same transaction or neither does. `setLaunchCap` takes a
///        poolId, which only exists after `createSpoke` runs, so the batch targets the id the new pool
///        will get (the current `poolCount`). If another pool is created between scheduling and
///        execution that id would belong to someone else, so `execute` refuses when `poolCount` has
///        moved. Re-schedule in that case.
///      - SALT (optional): timelock operation salt. Default 0. Must match between schedule and execute.
///      - ACTION (optional): "schedule" (default) or "execute".
contract CreateSpoke is Script {
    function _params()
        internal
        view
        returns (
            address store,
            TimelockController tl,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,
            uint256 delay,
            bytes32 salt,
            uint16 expectedPoolId
        )
    {
        store = vm.envAddress("STORE_PROXY");
        tl = TimelockController(payable(vm.envAddress("GOVERNOR_TIMELOCK")));
        address spokeAsset = vm.envAddress("SPOKE_ASSET");
        address priceFeed = vm.envAddress("SPOKE_FEED");
        uint256 minDlrs = vm.envOr("SPOKE_MIN_DLRS", uint256(0));
        uint256 launchCap = vm.envOr("SPOKE_LAUNCH_CAP", uint256(0));
        delay = tl.getMinDelay();
        salt = bytes32(vm.envOr("SALT", uint256(0)));
        expectedPoolId = uint16(DollarStore(store).poolCount());

        uint256 steps = launchCap == 0 ? 1 : 2;
        targets = new address[](steps);
        values = new uint256[](steps);
        payloads = new bytes[](steps);

        targets[0] = store;
        payloads[0] = abi.encodeCall(DollarStore.createSpoke, (spokeAsset, priceFeed, minDlrs));
        if (launchCap != 0) {
            targets[1] = store;
            payloads[1] = abi.encodeCall(DollarStore.setLaunchCap, (expectedPoolId, launchCap));
        }
    }

    /// @notice Queue the operation on the governor timelock (proposer key required).
    function schedule() public {
        (
            address store,
            TimelockController tl,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,
            uint256 delay,
            bytes32 salt,
            uint16 expectedPoolId
        ) = _params();
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(key);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.stopBroadcast();
        console2.log("scheduled createSpoke on:", store);
        console2.log("steps in the batch:      ", targets.length); // 2 when a launch cap is set
        console2.log("expected new poolId:     ", expectedPoolId);
        console2.log("executable after (s):    ", delay);
        console2.log("operation id:");
        console2.logBytes32(tl.hashOperationBatch(targets, values, payloads, bytes32(0), salt));
    }

    /// @notice Execute the queued operation once the timelock delay has elapsed.
    function execute() public {
        (
            address store,
            TimelockController tl,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,,
            bytes32 salt,
            uint16 expectedPoolId
        ) = _params();
        // The batch caps the pool id the spoke was going to get. If the registry grew in the meantime
        // that id is another pool, and executing would cap the wrong one.
        require(
            targets.length == 1 || uint16(DollarStore(store).poolCount()) == expectedPoolId,
            "poolCount moved since scheduling: re-schedule"
        );
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(key);
        tl.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();
        console2.log("executed createSpoke on:", store);
    }

    function run() external {
        string memory action = vm.envOr("ACTION", string("schedule"));
        if (keccak256(bytes(action)) == keccak256(bytes("execute"))) {
            execute();
        } else {
            schedule();
        }
    }
}
