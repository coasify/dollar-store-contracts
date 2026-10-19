// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SpokeQueueTriggerTest} from "./SpokeQueueTrigger.t.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {SpokeShareLib} from "../src/libraries/SpokeShareLib.sol";
import {Exits} from "./utils/Exits.sol";

/// @notice Recovery must isolate historical shares from all capital in a replacement pool.

contract SpokeImpairedRecoveryTest is SpokeQueueTriggerTest {
    uint256 internal constant CAPITAL = 1_000e6;
    uint256 internal constant NATIVE_CAPITAL = 1_000e18;
    uint256 internal constant SCALE = 1e12;
    uint8 internal constant KILLED = 2;

    function _fund() internal {
        vm.startPrank(alice);
        rlusd.approve(address(store), NATIVE_CAPITAL);
        store.deposit(spoke, address(rlusd), NATIVE_CAPITAL, alice, block.timestamp);
        vm.stopPrank();
    }

    function _impair() internal {
        _fund();
        rlusd.burn(address(store), NATIVE_CAPITAL);
        vm.prank(governor);
        store.syncReserves(spoke, address(rlusd));
    }

    function testFuzz_recreateIsolatesLegacyClaims(uint96 capital) public {
        uint256 units = bound(uint256(capital), 1, CAPITAL);
        _impair();
        vm.prank(governor);
        store.removePool(spoke);
        assertEq(store.getPoolStatus(spoke), KILLED);
        assertTrue(store.isPoolPaused(spoke));
        assertFalse(store.isAssetListed(address(rlusd)));
        assertEq(store.getReceiptShares(spoke, alice), CAPITAL);
        assertEq(store.getReceiptTotalShares(spoke), CAPITAL);

        vm.prank(governor);
        uint16 fresh = store.createSpoke(address(rlusd), address(feed), 0, 0);
        assertGt(fresh, spoke);
        vm.startPrank(bob);
        rlusd.approve(address(store), units * SCALE);
        (, uint256 shares) = store.deposit(fresh, address(rlusd), units * SCALE, bob, block.timestamp);
        assertEq(shares, units);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.withdraw(spoke, CAPITAL, new uint256[](0), block.timestamp);
        vm.expectPartialRevert(IDollarStore.InsufficientReceiptShares.selector);
        store.withdraw(fresh, 1, new uint256[](0), block.timestamp);
        vm.expectPartialRevert(IDollarStore.PoolPaused.selector);
        store.deposit(spoke, address(rlusd), units * SCALE, alice, block.timestamp);
        vm.expectPartialRevert(IDollarStore.PoolPaused.selector);
        store.deposit(spoke, address(usdc), units, alice, block.timestamp);
        vm.stopPrank();

        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolKilled.selector);
        store.removePool(spoke);
        vm.prank(unpauser);
        vm.expectPartialRevert(IDollarStore.PoolKilled.selector);
        store.unpausePool(spoke);
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.SpokeWindingDown.selector);
        store.windDownSpoke(spoke);
        assertTrue(store.isAssetListed(address(rlusd)));
        assertEq(store.assetPoolId(address(rlusd)), fresh);
        assertEq(store.getReserve(spoke, address(rlusd)), 0);
        assertEq(store.getReceiptShares(fresh, alice), 0);
        vm.prank(bob);
        (uint256 payout, uint256 hubPayout) = Exits.withdraw(store, fresh, units);
        assertEq(payout, units);
        assertEq(hubPayout, 0);
    }

    function test_impairmentBlocksBothDepositAssets() public {
        _impair();
        vm.startPrank(bob);
        rlusd.approve(address(store), NATIVE_CAPITAL);
        usdc.approve(address(store), CAPITAL);
        uint256 beforeSpoke = rlusd.balanceOf(bob);
        uint256 beforeHub = usdc.balanceOf(bob);
        vm.expectRevert(SpokeShareLib.PoolFullyImpaired.selector);
        store.deposit(spoke, address(rlusd), NATIVE_CAPITAL, bob, block.timestamp);
        vm.expectRevert(SpokeShareLib.PoolFullyImpaired.selector);
        store.deposit(spoke, address(usdc), CAPITAL, bob, block.timestamp);
        vm.stopPrank();
        assertEq(rlusd.balanceOf(bob), beforeSpoke);
        assertEq(usdc.balanceOf(bob), beforeHub);
        assertEq(store.getReceiptTotalShares(spoke), CAPITAL);
    }

    function test_blockedEscrowPreservedUntilCancellationSucceeds() public {
        _impair();
        _queue(bob, rlusd, usdc, NATIVE_CAPITAL);
        uint256 position = store.getUserQueuePositions(bob)[0];
        rlusd.setBlocked(bob, true);
        vm.prank(bob);
        store.cancelQueue(position);
        assertTrue(store.isQueuePositionParked(position));
        assertEq(store.getQueueDepth(address(rlusd), address(usdc)), 0);
        assertEq(store.getQueueDepth(address(rlusd), address(0)), CAPITAL);
        assertEq(store.getReceiptShares(spoke, bob), 0);
        vm.prank(governor);
        store.removePool(spoke);
        assertEq(store.getPoolStatus(spoke), KILLED);
        vm.prank(bob);
        vm.expectPartialRevert(IDollarStore.EscrowTransferFailed.selector);
        store.cancelQueue(position);
        rlusd.setBlocked(bob, false);
        uint256 before = rlusd.balanceOf(bob);
        vm.prank(bob);
        store.cancelQueue(position);
        assertEq(rlusd.balanceOf(bob) - before, NATIVE_CAPITAL);
    }

    function test_recreatedPool_blockedCancelParksWithoutTouchingEitherPool() public {
        _impair();
        vm.prank(governor);
        store.removePool(spoke);
        vm.prank(governor);
        uint16 fresh = store.createSpoke(address(rlusd), address(feed), 0, 0);
        _queue(bob, rlusd, usdc, NATIVE_CAPITAL);
        uint256 position = store.getUserQueuePositions(bob)[0];
        rlusd.setBlocked(bob, true);
        vm.prank(bob);
        store.cancelQueue(position);
        assertTrue(store.isQueuePositionParked(position));
        assertEq(store.getReceiptShares(fresh, bob), 0);
        assertEq(store.getReceiptShares(spoke, bob), 0);
        assertEq(store.getReserve(spoke, address(rlusd)), 0);
        assertEq(store.getReserve(fresh, address(rlusd)), 0);
    }

    function test_incomingQueueDoesNotBlockRemoval() public {
        _impair();
        _queue(bob, usdc, rlusd, CAPITAL);
        uint256 position = store.getUserQueuePositions(bob)[0];
        vm.prank(governor);
        store.removePool(spoke);
        assertEq(store.getPoolStatus(spoke), KILLED);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        store.cancelQueue(position);
        assertEq(usdc.balanceOf(bob) - before, CAPITAL);
    }

    function test_residualSpokeReserveBlocksRemoval() public {
        _fund();
        rlusd.burn(address(store), NATIVE_CAPITAL - SCALE);
        vm.prank(governor);
        store.syncReserves(spoke, address(rlusd));
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolNotEmpty.selector);
        store.removePool(spoke);
    }

    function test_dlrsReserveBlocksRemoval() public {
        vm.startPrank(alice);
        usdc.approve(address(store), CAPITAL);
        store.deposit(spoke, address(usdc), CAPITAL, alice, block.timestamp);
        vm.stopPrank();
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolNotEmpty.selector);
        store.removePool(spoke);
    }
}
