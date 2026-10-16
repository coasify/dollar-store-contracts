// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockReentrantERC20} from "./mocks/MockReentrantERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice A ready governor operation executed through the open timelock executor from inside a
///         token payout callback cannot run mid-flight.
/// @dev The governor is a TimelockController with an open executor, as deployed. `evil` calls the
///      timelock's `execute` on its next payout from the store.
contract GovernorReentrancyTest is Test {
    DollarStore internal store;
    TimelockController internal timelock;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sink = makeAddr("sink");

    MockERC20 internal usdc;
    MockReentrantERC20 internal evil;

    function setUp() public {
        vm.warp(1_000); // the timelock reads timestamp 1 as "done"
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1); // address(0): anyone may execute
        timelock = new TimelockController(0, proposers, executors, address(0));

        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize,
            (
                makeAddr("upgrader"),
                address(timelock),
                makeAddr("guardian"),
                makeAddr("unpauser"),
                Pausers.one(makeAddr("pauser"))
            )
        );
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        evil = new MockReentrantERC20("Evil", "EVIL", 6);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);
        _govern(abi.encodeCall(DollarStore.addHubAsset, (address(usdc), address(feed))));
        _govern(abi.encodeCall(DollarStore.addHubAsset, (address(evil), address(feed))));

        usdc.mint(alice, 1_000_000e6);
        evil.mint(alice, 1_000_000e6);
        evil.mint(bob, 1_000_000e6);
    }

    // ============ Helpers ============

    function _schedule(bytes memory payload) internal {
        timelock.schedule(address(store), 0, payload, bytes32(0), keccak256(payload), 0);
    }

    function _execute(bytes memory payload) internal {
        timelock.execute(address(store), 0, payload, bytes32(0), keccak256(payload));
    }

    function _govern(bytes memory payload) internal {
        _schedule(payload);
        _execute(payload);
    }

    /// @dev Schedules `payload` and arms `evil` to execute it on the next payout from the store.
    function _armReady(bytes memory payload) internal {
        _schedule(payload);
        evil.armCall(
            address(store),
            address(timelock),
            abi.encodeCall(TimelockController.execute, (address(store), 0, payload, bytes32(0), keccak256(payload)))
        );
    }

    function _deposit(address who, address token, uint256 amt) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(store), amt);
        store.deposit(0, token, amt, block.timestamp);
        vm.stopPrank();
    }

    // ============ rescueTokens ============

    /// @notice A rescue run from the swap's payout, before the remainder is booked as escrow,
    ///         reverts the swap instead of sweeping the remainder.
    function test_rescueTokens_fromSwapPayout_reverts() public {
        _deposit(bob, address(evil), 400e6);
        _armReady(abi.encodeCall(DollarStore.rescueTokens, (address(usdc), sink)));

        vm.startPrank(alice);
        usdc.approve(address(store), 1_000e6);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        store.swap(address(usdc), address(evil), 1_000e6, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @notice Positive control: the same rescue run after the swap sweeps only the donated excess.
    function test_rescueTokens_afterSwap_sweepsOnlyExcess() public {
        _deposit(bob, address(evil), 400e6);
        vm.startPrank(alice);
        usdc.approve(address(store), 1_000e6);
        (, uint256 queued) = store.swap(address(usdc), address(evil), 1_000e6, 0, 0, block.timestamp);
        usdc.transfer(address(store), 5e6); // donation
        vm.stopPrank();
        assertEq(queued, 600e6, "remainder queued");

        _govern(abi.encodeCall(DollarStore.rescueTokens, (address(usdc), sink)));

        assertEq(usdc.balanceOf(sink), 5e6, "only the donation swept");
        assertEq(usdc.balanceOf(address(store)), 1_000e6, "reserve and escrow stay backed");
    }
}
