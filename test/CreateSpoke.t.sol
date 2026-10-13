// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {CreateSpoke} from "../script/CreateSpoke.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice `createSpoke` with a launch cap, and `script/CreateSpoke.s.sol` run against a real governor timelock
///         with more than one spoke creation queued at the same time.
contract CreateSpokeScriptTest is Test {
    uint256 internal constant PROPOSER_KEY = 0xA11CE;
    uint256 internal constant DELAY = 7 days;

    DollarStore internal store;
    TimelockController internal governorTL;
    CreateSpoke internal script;
    MockERC20 internal usdc;
    MockERC20 internal spokeA;
    MockERC20 internal spokeB;
    MockAggregatorV3 internal feed;

    address internal anyone = makeAddr("anyone");

    event LaunchCapSet(uint16 indexed poolId, uint256 cap);

    struct Queued {
        address target;
        bytes data;
    }

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = vm.addr(PROPOSER_KEY);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution, as in production
        governorTL = new TimelockController(DELAY, proposers, executors, address(0));

        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize,
            (
                makeAddr("upgrader"),
                address(governorTL),
                makeAddr("guardian"),
                makeAddr("unpauser"),
                Pausers.one(makeAddr("pauser"))
            )
        );
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        spokeA = new MockERC20("Spoke A", "SPA", 6);
        spokeB = new MockERC20("Spoke B", "SPB", 18);
        feed = new MockAggregatorV3(8, 1e8);
        vm.prank(address(governorTL));
        store.addHubAsset(address(usdc), address(feed));

        script = new CreateSpoke();
    }

    function _params(MockERC20 asset, uint256 cap) internal view returns (CreateSpoke.Params memory p) {
        p.key = PROPOSER_KEY;
        p.store = address(store);
        p.tl = governorTL;
        p.spokeAsset = address(asset);
        p.priceFeed = address(feed);
        p.launchCap = cap;
    }

    /// @dev Run the script's `schedule` and return the call the timelock recorded, which is what anyone
    ///      watching the chain can replay through the open executor.
    function _schedule(MockERC20 asset, uint256 cap) internal returns (Queued memory q) {
        vm.recordLogs();
        script.schedule(_params(asset, cap));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            (q.target,, q.data,,) = abi.decode(logs[i].data, (address, uint256, bytes, bytes32, uint256));
        }
    }

    function _execute(Queued memory q) internal {
        vm.prank(anyone);
        governorTL.execute(q.target, 0, q.data, bytes32(0), bytes32(0));
    }

    // ============ Two spokes queued in the same waiting period ============

    /// @notice Each spoke ends with the cap it was queued with, in whichever order they are executed.
    function test_twoSpokesQueuedTogether_eachGetsItsOwnCap() public {
        Queued memory a = _schedule(spokeA, 1_000_000e6);
        Queued memory b = _schedule(spokeB, 500_000e6);
        vm.warp(vm.getBlockTimestamp() + DELAY);

        _execute(a);
        _execute(b);
        assertEq(store.getLaunchCap(store.assetPoolId(address(spokeA))), 1_000_000e6, "spoke A has its own cap");
        assertEq(store.getLaunchCap(store.assetPoolId(address(spokeB))), 500_000e6, "spoke B has its own cap");
    }

    function test_twoSpokesQueuedTogether_executedInReverse_eachGetsItsOwnCap() public {
        Queued memory a = _schedule(spokeA, 1_000_000e6);
        Queued memory b = _schedule(spokeB, 500_000e6);
        vm.warp(vm.getBlockTimestamp() + DELAY);

        _execute(b);
        _execute(a);
        assertEq(store.assetPoolId(address(spokeB)), 1, "the one executed first takes the next id");
        assertEq(store.assetPoolId(address(spokeA)), 2);
        assertEq(store.getLaunchCap(1), 500_000e6, "spoke B has its own cap");
        assertEq(store.getLaunchCap(2), 1_000_000e6, "spoke A has its own cap");
    }

    // ============ The script, schedule then execute ============

    function test_script_scheduleThenExecute_createsAndCaps() public {
        _schedule(spokeA, 250_000e6);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        script.execute(_params(spokeA, 250_000e6));
        assertEq(store.assetPoolId(address(spokeA)), 1);
        assertEq(store.getLaunchCap(1), 250_000e6);
    }

    function test_script_execute_revertsBeforeTheDelay() public {
        _schedule(spokeA, 250_000e6);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        script.execute(_params(spokeA, 250_000e6));
    }

    function test_script_withoutCap_launchesUncapped() public {
        Queued memory q = _schedule(spokeA, 0);
        assertEq(bytes4(q.data), DollarStore.createSpoke.selector);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        script.execute(_params(spokeA, 0));
        assertEq(store.assetPoolId(address(spokeA)), 1);
        assertEq(store.getLaunchCap(1), 0);
    }

    // ============ createSpoke with a cap ============

    function test_createSpoke_setsFloorAndCap_andTheCapBites() public {
        vm.expectEmit(true, false, false, true, address(store));
        emit LaunchCapSet(1, 250_000e6);
        vm.prank(address(governorTL));
        uint16 poolId = store.createSpoke(address(spokeB), address(feed), 150_000e6, 250_000e6);
        assertEq(poolId, 1);
        assertEq(store.getMinDlrsReserve(1), 150_000e6);
        assertEq(store.getLaunchCap(1), 250_000e6);

        spokeB.mint(anyone, 300_000e18);
        vm.startPrank(anyone);
        spokeB.approve(address(store), 300_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.LaunchCapExceeded.selector, 1, 300_000e6, 250_000e6));
        store.deposit(1, address(spokeB), 300_000e18, block.timestamp);
        store.deposit(1, address(spokeB), 250_000e18, block.timestamp);
        vm.stopPrank();
    }

    function test_createSpoke_withCap_onlyGovernor() public {
        vm.prank(anyone);
        vm.expectRevert(IDollarStore.OnlyGovernor.selector);
        store.createSpoke(address(spokeA), address(feed), 0, 1e6);
    }

    function test_createSpoke_zeroCap_leavesThePoolUncapped() public {
        vm.prank(address(governorTL));
        store.createSpoke(address(spokeA), address(feed), 0, 0);
        assertEq(store.getLaunchCap(1), 0);
    }
}
