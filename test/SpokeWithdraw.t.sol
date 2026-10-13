// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {DLRS} from "../src/DLRS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice Spoke exits: an LP burns receipt shares and receives their proportional slice of the spoke
///         asset and of the spoke's claim on hub dollars. Exits stay live under pause and are never
///         blocked by minDlrsReserve.
contract SpokeWithdrawTest is Test {
    DollarStore internal store;
    DLRS internal dlrs;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal rlusd; // 18dp spoke asset
    MockAggregatorV3 internal feed;

    uint16 internal spoke;

    event SpokeWithdrawn(
        uint16 indexed poolId, address indexed provider, uint256 sharesBurned, uint256 spokeUnits, uint256 hubUnits
    );

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser, Pausers.one(pauser)));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        dlrs = DLRS(store.dlrs());

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usdt), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0, 0);
        vm.stopPrank();

        address[3] memory who = [alice, bob, trader];
        for (uint256 i; i < 3; i++) {
            usdc.mint(who[i], 1_000_000e6);
            usdt.mint(who[i], 1_000_000e6);
            rlusd.mint(who[i], 1_000_000e18);
            vm.startPrank(who[i]);
            usdc.approve(address(store), type(uint256).max);
            usdt.approve(address(store), type(uint256).max);
            rlusd.approve(address(store), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _depositSpokeAsset(address who, uint256 nativeAmt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = store.deposit(spoke, address(rlusd), nativeAmt, block.timestamp);
    }

    function _fund(address who, MockERC20 hub, uint256 nativeAmt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = store.deposit(spoke, address(hub), nativeAmt, block.timestamp);
    }

    // ============ One-sided pools: the slice is whatever the pool holds ============

    function test_withdraw_spokeAssetOnlyPool_roundTrip() public {
        _depositSpokeAsset(alice, 1_000e18); // 1000e6 shares, pool = 1000 RLUSD + 0 claim

        vm.expectEmit(true, true, false, true, address(store));
        emit SpokeWithdrawn(spoke, alice, 1_000e6, 1_000e6, 0);
        vm.prank(alice);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, 1_000e6, block.timestamp);

        assertEq(spokeUnits, 1_000e6);
        assertEq(hubUnits, 0);
        assertEq(rlusd.balanceOf(alice), 1_000_000e18, "full round-trip");
        assertEq(store.getReceiptShares(spoke, alice), 0);
        assertEq(store.getReceiptTotalShares(spoke), 0);
        assertEq(store.getReserve(spoke, address(rlusd)), 0);
    }

    function test_withdraw_partial() public {
        _depositSpokeAsset(alice, 1_000e18);
        vm.prank(alice);
        (uint256 spokeUnits,) = store.withdraw(spoke, 400e6, block.timestamp);
        assertEq(spokeUnits, 400e6);
        assertEq(rlusd.balanceOf(alice), 1_000_000e18 - 600e18);
        assertEq(store.getReceiptShares(spoke, alice), 600e6);
        assertEq(store.getReserve(spoke, address(rlusd)), 600e6);
    }

    function test_withdraw_fundingOnlyPool_paysHubDollarsAcrossHubAssets() public {
        _fund(alice, usdc, 600e6); // claim 600, hub usdc 600
        _fund(alice, usdt, 400e6); // claim 1000, hub usdt 400, shares 1000

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdtBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, 500e6, block.timestamp);

        assertEq(spokeUnits, 0, "no spoke asset in the pool");
        assertEq(hubUnits, 500e6);
        // Hub leg is itself proportional to the hub's reserves (600:400), never the LP's choice.
        assertEq(usdc.balanceOf(alice) - usdcBefore, 300e6);
        assertEq(usdt.balanceOf(alice) - usdtBefore, 200e6);
        assertEq(store.getDlrsReserve(spoke), 500e6);
        assertEq(
            dlrs.totalSupply() + store.getDlrsReserve(spoke),
            store.getReserve(0, address(usdc)) + store.getReserve(0, address(usdt)),
            "conservation"
        );
    }

    // ============ Mixed pool: both legs, always ============

    function test_withdraw_mixedPool_paysBothLegs() public {
        _depositSpokeAsset(alice, 1_000e18); // 1000 RLUSD, shares 1000
        _fund(bob, usdc, 1_000e6); // claim 1000, shares 2000 total

        uint256 rlBefore = rlusd.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, 1_000e6, block.timestamp);

        // Alice put in only RLUSD but the pool is 50/50, so she leaves 50/50.
        assertEq(spokeUnits, 500e6);
        assertEq(hubUnits, 500e6);
        assertEq(rlusd.balanceOf(alice) - rlBefore, 500e18);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 500e6);
    }

    /// @notice A deposit followed by a withdraw hands back the pool's mix, never a chosen asset. Exits
    ///         are senior to minDlrsReserve and do not settle the queue, so this route still moves the
    ///         pool-mix fraction of a fresh deposit into hub assets and can take the claim below the
    ///         floor. This test pins that behavior explicitly.
    function test_withdraw_returnsPoolMix_exitsAreSeniorToFloor() public {
        _fund(bob, usdc, 1_000_000e6); // claim 1,000,000
        vm.prank(governor);
        store.setMinDlrsReserve(spoke, 900_000e6);

        // A seller who tries the sanctioned path is capped by the floor.
        vm.prank(trader);
        (uint256 filled, uint256 queued) = store.swap(address(rlusd), address(usdc), 500_000e18, 0, 0, block.timestamp);
        assertEq(filled, 100_000e6);
        assertEq(queued, 400_000e6);

        // The LP route: deposit 900k RLUSD, withdraw everything. Pool is 600k RLUSD + 900k claim.
        uint256 rlBefore = rlusd.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 shares = store.deposit(spoke, address(rlusd), 900_000e18, block.timestamp);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, shares, block.timestamp);
        vm.stopPrank();

        // She gets her share of the MIX: 900k of 1.9M total value is 47.4% of each side, so 473,684 of
        // her RLUSD comes straight back and 426,316 USDC is paid from the claim. Net: she converted
        // 426,316 RLUSD into USDC, the pool-mix fraction of her deposit, and not one dollar more.
        assertApproxEqAbs(spokeUnits + hubUnits, 900_000e6, 1, "value preserved (floor rounding, 1 unit at most)");
        assertApproxEqAbs(usdc.balanceOf(alice) - usdcBefore, 426_316e6, 1e6, "47.4% of the 900k claim");
        assertApproxEqAbs(rlBefore - rlusd.balanceOf(alice), 426_316e18, 1e18, "net RLUSD converted");
        // Documented consequences: the claim is now below the 900k floor, and the queued seller is
        // untouched (not jumped, but not settled either).
        assertLt(store.getDlrsReserve(spoke), 900_000e6, "exits are senior to minDlrsReserve");
        assertGt(store.getDlrsReserve(spoke), 470_000e6, "the claim is not drained");
        assertEq(store.getQueueDepth(address(rlusd), address(usdc)), 400_000e6, "queue untouched");
    }

    // ============ Dust: a share worth one unit can always be paid ============

    /// @notice Two owners with one share each, one unit on each side. Flooring per side would pay 0 + 0
    ///         and strand both; flooring on total value pays one unit to the first and one to the second,
    ///         draining the pool to exactly zero.
    function test_withdraw_dustPositions_canAlwaysExit() public {
        // Build the state: alice supplies 1 unit of RLUSD, bob funds 1 unit of USDC.
        vm.prank(alice);
        store.deposit(spoke, address(rlusd), 1e12, block.timestamp); // 1 unit = 1e12 wei of 18dp
        vm.prank(bob);
        store.deposit(spoke, address(usdc), 1, block.timestamp); // 1 unit
        assertEq(store.getReceiptTotalShares(spoke), 2);
        assertEq(store.getReserve(spoke, address(rlusd)), 1);
        assertEq(store.getDlrsReserve(spoke), 1);

        vm.prank(alice);
        (uint256 s1, uint256 h1) = store.withdraw(spoke, 1, block.timestamp);
        assertEq(s1 + h1, 1, "first share pays exactly one unit");

        vm.prank(bob);
        (uint256 s2, uint256 h2) = store.withdraw(spoke, 1, block.timestamp);
        assertEq(s2 + h2, 1, "second share pays the other unit");

        assertEq(store.getReserve(spoke, address(rlusd)), 0);
        assertEq(store.getDlrsReserve(spoke), 0);
        assertEq(store.getReceiptTotalShares(spoke), 0, "pool drained to zero, removable");
    }

    /// @notice The hub leg never exceeds the claim: rounding excess lands on the spoke side.
    function test_withdraw_roundingNeverOverpaysHubLeg() public {
        vm.prank(alice);
        store.deposit(spoke, address(rlusd), 3e12, block.timestamp); // 3 units RLUSD, 3 shares
        vm.prank(bob);
        store.deposit(spoke, address(usdc), 1, block.timestamp); // claim 1, 4 shares, pool value 4
        vm.prank(alice);
        (uint256 s1, uint256 h1) = store.withdraw(spoke, 3, block.timestamp); // value 3
        assertEq(s1 + h1, 3);
        assertLe(h1, 1, "hub leg capped by the claim");
        assertEq(store.getReserve(spoke, address(rlusd)) + store.getDlrsReserve(spoke), 1, "one unit left for bob");
    }

    // ============ Exit stays live under pause and ignores minDlrsReserve ============

    function test_withdraw_liveUnderGlobalPause() public {
        _depositSpokeAsset(alice, 1_000e18);
        vm.prank(pauser);
        store.pause();
        vm.prank(alice);
        (uint256 spokeUnits,) = store.withdraw(spoke, 1_000e6, block.timestamp);
        assertEq(spokeUnits, 1_000e6, "exit works while globally paused");
    }

    function test_withdraw_notBlockedByMinDlrsReserve() public {
        vm.prank(governor);
        store.setMinDlrsReserve(spoke, 5_000e6);
        _fund(alice, usdc, 1_000e6);
        vm.prank(alice);
        (, uint256 hubUnits) = store.withdraw(spoke, 1_000e6, block.timestamp);
        assertEq(hubUnits, 1_000e6, "min floor does not block a proportional LP exit");
        assertEq(store.getDlrsReserve(spoke), 0);
    }

    // ============ Reverts ============

    function test_withdraw_revertsInsufficientShares() public {
        _depositSpokeAsset(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, uint256(2_000e6), uint256(1_000e6))
        );
        store.withdraw(spoke, 2_000e6, block.timestamp);
    }

    function test_withdraw_revertsZeroShares() public {
        _depositSpokeAsset(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.withdraw(spoke, 0, block.timestamp);
    }

    function test_withdraw_revertsExpiredDeadline() public {
        _depositSpokeAsset(alice, 1_000e18);
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.DeadlineExpired.selector, uint256(999), uint256(1000)));
        store.withdraw(spoke, 1_000e6, 999);
    }

    /// @dev Impairs the spoke so poolValue << totalShares; burning 1 share then rounds to 0 on both legs.
    function test_withdraw_revertsZeroValueOnImpairment() public {
        _depositSpokeAsset(alice, 1_000e18);
        rlusd.burn(address(store), 999e18);
        vm.prank(governor);
        store.syncReserves(spoke, address(rlusd)); // reserve 1000e6 -> 1e6
        vm.prank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.withdraw(spoke, 1, block.timestamp);
    }

    function test_withdraw_revertsInvalidPool() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidPool.selector, uint16(7)));
        store.withdraw(7, 1, block.timestamp);
    }
}
