// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
///        `createSpoke` sets it in the same call, so the operation names no pool id and any number of
///        spokes can be queued in one waiting period and executed in any order.
///      - SALT (optional): timelock operation salt. Default 0. Must match between schedule and execute.
///      - ACTION (optional): "schedule" (default) or "execute".
contract CreateSpoke is Script {
    /// @notice What one run needs. `fromEnv` fills it from the environment.
    struct Params {
        uint256 key;
        address store;
        TimelockController tl;
        address spokeAsset;
        address priceFeed;
        uint256 minDlrs;
        uint256 launchCap;
        bytes32 salt;
    }

    function fromEnv() public view returns (Params memory p) {
        p.key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        p.store = vm.envAddress("STORE_PROXY");
        p.tl = TimelockController(payable(vm.envAddress("GOVERNOR_TIMELOCK")));
        p.spokeAsset = vm.envAddress("SPOKE_ASSET");
        p.priceFeed = vm.envAddress("SPOKE_FEED");
        p.minDlrs = vm.envOr("SPOKE_MIN_DLRS", uint256(0));
        p.launchCap = vm.envOr("SPOKE_LAUNCH_CAP", uint256(0));
        p.salt = bytes32(vm.envOr("SALT", uint256(0)));
    }

    /// @notice The governor call that creates the spoke with its launch cap.
    function payload(Params memory p) public pure returns (bytes memory) {
        return abi.encodeCall(DollarStore.createSpoke, (p.spokeAsset, p.priceFeed, p.minDlrs, p.launchCap));
    }

    /// @notice Queue the operation on the governor timelock (proposer key required).
    function schedule(Params memory p) public {
        bytes memory data = payload(p);
        uint256 delay = p.tl.getMinDelay();
        vm.startBroadcast(p.key);
        p.tl.schedule(p.store, 0, data, bytes32(0), p.salt, delay);
        vm.stopBroadcast();
        console2.log("scheduled createSpoke on:", p.store);
        console2.log("launch cap (6dp, 0 = none):", p.launchCap);
        console2.log("executable after (s):    ", delay);
        console2.log("operation id:");
        console2.logBytes32(p.tl.hashOperation(p.store, 0, data, bytes32(0), p.salt));
    }

    /// @notice Execute the queued operation once the timelock delay has elapsed.
    function execute(Params memory p) public {
        vm.startBroadcast(p.key);
        p.tl.execute(p.store, 0, payload(p), bytes32(0), p.salt);
        vm.stopBroadcast();
        console2.log("executed createSpoke on:", p.store);
    }

    function run() external {
        string memory action = vm.envOr("ACTION", string("schedule"));
        if (keccak256(bytes(action)) == keccak256(bytes("execute"))) {
            execute(fromEnv());
        } else {
            schedule(fromEnv());
        }
    }
}
