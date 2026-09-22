// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SpokeQueueTriggerTest} from "./SpokeQueueTrigger.t.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {SpokeShareLib} from "../src/libraries/SpokeShareLib.sol";

/// @notice Recovery must isolate historical shares from all capital in a replacement pool.
contract SpokeImpairedRecoveryTest is SpokeQueueTriggerTest {
    uint256 internal constant CAPITAL = 1_000e6;
    uint256 internal constant NATIVE_CAPITAL = 1_000e18;
    uint256 internal constant SCALE = 1e12;
    uint8 internal constant KILLED = 2;

    function _fund() internal {
        vm.startPrank(alice);
        rlusd.approve(address(store), NATIVE_CAPITAL);
        store.deposit(spoke, address(rlusd), NATIVE_CAPITAL, block.timestamp);
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
        uint16 fresh = store.createSpoke(address(rlusd), address(feed), 0);
        assertGt(fresh, spoke);
        vm.startPrank(bob);
        rlusd.approve(address(store), units * SCALE);
        assertEq(store.deposit(fresh, address(rlusd), units * SCALE, block.timestamp), units);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.redeemSpoke(spoke, CAPITAL, block.timestamp);
        vm.expectPartialRevert(IDollarStore.InsufficientReceiptShares.selector);
        store.redeemSpoke(fresh, 1, block.timestamp);
        vm.expectPartialRevert(IDollarStore.WrongPool.selector);
        store.withdraw(spoke, address(rlusd), CAPITAL, block.timestamp);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.withdraw(spoke, address(usdc), CAPITAL, block.timestamp);
        vm.expectPartialRevert(IDollarStore.PoolPaused.selector);
        store.deposit(spoke, address(rlusd), units * SCALE, block.timestamp);
        vm.expectPartialRevert(IDollarStore.PoolPaused.selector);
        store.deposit(spoke, address(usdc), units, block.timestamp);
        vm.stopPrank();

        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolKilled.selector);
        store.removePool(spoke);
        vm.prank(guardian);
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
        (uint256 payout, uint256 hubPayout) = store.redeemSpoke(fresh, units, block.timestamp);
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
        store.deposit(spoke, address(rlusd), NATIVE_CAPITAL, block.timestamp);
        vm.expectRevert(SpokeShareLib.PoolFullyImpaired.selector);
        store.deposit(spoke, address(usdc), CAPITAL, block.timestamp);
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
        vm.expectRevert(SpokeShareLib.PoolFullyImpaired.selector);
        store.cancelQueue(position);
        assertEq(store.getQueueDepth(address(rlusd), address(usdc)), CAPITAL);
        assertEq(store.getReceiptShares(spoke, bob), 0);
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolNotEmpty.selector);
        store.removePool(spoke);
        rlusd.setBlocked(bob, false);
        vm.prank(bob);
        store.cancelQueue(position);
        vm.prank(governor);
        store.removePool(spoke);
        assertEq(store.getPoolStatus(spoke), KILLED);
    }

    function test_recreatedPoolReceivesEscrowConversionAndSwaps() public {
        _impair();
        vm.prank(governor);
        store.removePool(spoke);
        vm.prank(governor);
        uint16 fresh = store.createSpoke(address(rlusd), address(feed), 0);
        _queue(bob, rlusd, usdc, NATIVE_CAPITAL);
        uint256 position = store.getUserQueuePositions(bob)[0];
        rlusd.setBlocked(bob, true);
        vm.prank(bob);
        store.cancelQueue(position);
        assertEq(store.getReceiptShares(fresh, bob), CAPITAL);
        assertEq(store.getReceiptShares(spoke, bob), 0);
        assertEq(store.getReserve(spoke, address(rlusd)), 0);
        assertEq(store.getReserve(fresh, address(rlusd)), CAPITAL);
        vm.startPrank(alice);
        usdc.approve(address(store), CAPITAL);
        store.swap(address(usdc), address(rlusd), CAPITAL, 0, 0, block.timestamp);
        vm.stopPrank();
        assertEq(store.getDlrsReserve(fresh), CAPITAL);
        assertEq(store.getDlrsReserve(spoke), 0);
        vm.prank(bob);
        (uint256 spokeOut, uint256 hubOut) = store.redeemSpoke(fresh, CAPITAL, block.timestamp);
        assertEq(spokeOut, 0);
        assertEq(hubOut, CAPITAL);
    }

    function test_incomingQueueBlocksRemoval() public {
        _impair();
        _queue(bob, usdc, rlusd, CAPITAL);
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolNotEmpty.selector);
        store.removePool(spoke);
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
        store.deposit(spoke, address(usdc), CAPITAL, block.timestamp);
        vm.stopPrank();
        vm.prank(governor);
        vm.expectPartialRevert(IDollarStore.PoolNotEmpty.selector);
        store.removePool(spoke);
    }
}
