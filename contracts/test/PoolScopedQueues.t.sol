// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice Queue keys are scoped by pool, so a killed-and-relisted spoke never shares lines with its
///         predecessor: a leftover position cannot hold a spoke open, and a haircut after a relist
///         walks the live line once.
contract PoolScopedQueuesTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal upgrader = makeAddr("upgrader");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    MockERC20 internal usdc; // 6dp hub asset
    MockERC20 internal usdt; // 6dp hub asset
    MockERC20 internal rlusd; // 18dp spoke asset
    MockAggregatorV3 internal feed;

    uint16 internal spoke;

    event QueueJoined(
        uint256 indexed positionId,
        address indexed owner,
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint16 poolId
    );

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usdt), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0);
        vm.stopPrank();

        address[4] memory who = [lp, alice, carol, dave];
        for (uint256 i; i < 4; i++) {
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

    /// @dev `who` queues a buy of RLUSD with USDC against a spoke that holds no RLUSD.
    function _queueBuyer(address who, uint256 usdcNative) internal returns (uint256 id) {
        vm.prank(who);
        (uint256 filled, uint256 queued) = store.swap(address(usdc), address(rlusd), usdcNative, 0, 0, block.timestamp);
        assertEq(filled, 0);
        assertEq(queued, usdcNative);
        id = store.getUserQueuePositions(who)[0];
    }

    /// @dev Wind the spoke down, then queue a buyer. Nothing can ever put RLUSD into a winding-down
    ///      spoke, so the position can only be cancelled.
    function _windDownAndQueueBuyer(address who, uint256 usdcNative) internal returns (uint256 id) {
        vm.prank(governor);
        store.windDownSpoke(spoke);
        id = _queueBuyer(who, usdcNative);
    }

    /// @dev Remove the (wound-down) spoke and list its asset again as a new spoke.
    function _removeAndRelist() internal returns (uint16 spoke2) {
        vm.startPrank(governor);
        store.removePool(spoke);
        spoke2 = store.createSpoke(address(rlusd), address(feed), 0);
        vm.stopPrank();
        assertEq(spoke2, spoke + 1, "fresh pool id");
    }

    function _amount(uint256 id) internal view returns (uint256 amt) {
        (,,, amt,,) = store.getQueuePosition(id);
    }

    // ============ Dust in a winding-down spoke's line does not block retirement ============

    function test_removePool_dustInWindingDownLine_doesNotBlock() public {
        // One base unit of USDC: below the minimum order size, allowed as the first position of an empty line.
        uint256 id = _windDownAndQueueBuyer(dave, 1);

        vm.prank(governor);
        store.removePool(spoke);
        assertEq(store.getPoolStatus(spoke), 2, "killed despite the queued position");
        assertFalse(store.isAssetListed(address(rlusd)));

        // The pair no longer routes anywhere, so the pair-based views report an empty line until a relist.
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0, "removed pool's depth not reported");
        assertEq(store.getMinimumOrderSize(address(usdc), address(rlusd)), 500e6, "base minimum");

        // Dave's escrow is intact, still tagged with the killed pool, and he can take it back whenever he likes.
        (address owner,,, uint256 amt,, uint16 pid) = store.getQueuePosition(id);
        assertEq(owner, dave);
        assertEq(amt, 1);
        assertEq(pid, spoke);
        uint256 before = usdc.balanceOf(dave);
        vm.prank(dave);
        store.cancelQueue(id);
        assertEq(usdc.balanceOf(dave) - before, 1);
    }

    // ============ Relist: the new spoke starts with fresh lines in both directions ============

    function test_relist_freshLines_oldPositionsUnreachable() public {
        // A funded spoke: the LP holds all its shares. Alice sells RLUSD for USDT (no USDT in the spoke:
        // queued). Governance winds the spoke down and the LP redeems in full, so reserves and shares
        // are zero. Dave then buys RLUSD with USDC; the spoke is empty, so he is queued. Different pairs,
        // so Alice and Dave never match each other.
        vm.prank(lp);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.prank(alice);
        (, uint256 queuedSell) = store.swap(address(rlusd), address(usdt), 500e18, 0, 0, block.timestamp);
        assertEq(queuedSell, 500e6);
        uint256 sellId = store.getUserQueuePositions(alice)[0];
        vm.prank(governor);
        store.windDownSpoke(spoke);
        uint256 lpShares = store.getReceiptShares(spoke, lp);
        vm.prank(lp);
        store.redeemSpoke(spoke, lpShares, block.timestamp);
        assertEq(store.getReserve(spoke, address(rlusd)), 0, "LP took the whole reserve");
        assertEq(store.getReceiptTotalShares(spoke), 0, "no shares left");
        uint256 buyId = _queueBuyer(dave, 500e6);

        // The two leftover positions are the only thing left in the spoke, and they do not block removal.
        uint16 spoke2 = _removeAndRelist();

        // The pair-based views now describe the live spoke's lines: empty, base minimum order size.
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0);
        assertEq(store.getQueueDepth(address(rlusd), address(usdt)), 0);
        assertEq(store.getMinimumOrderSize(address(usdc), address(rlusd)), 500e6);

        // Carol sells RLUSD for USDT in the new spoke: same pair as Alice, live line.
        vm.prank(carol);
        store.swap(address(rlusd), address(usdt), 200e18, 0, 0, block.timestamp);
        uint256 liveSellId = store.getUserQueuePositions(carol)[0];

        // Liquidity arriving in the new spoke, in either direction, settles ITS lines only.
        vm.startPrank(lp);
        store.deposit(spoke2, address(rlusd), 1_000e18, block.timestamp);
        store.deposit(spoke2, address(usdt), 1_000e6, block.timestamp);
        vm.stopPrank();
        assertEq(_amount(liveSellId), 0, "live seller settled by the successor's USDT");
        assertEq(_amount(buyId), 500e6, "old buyer not settled by the successor's RLUSD");
        assertEq(_amount(sellId), 500e6, "old seller not settled by the successor's USDT");

        // And the new spoke trades instantly: no same-direction position blocks reserve fills.
        vm.prank(carol);
        assertEq(store.swapExactInput(address(usdc), address(rlusd), 100e6, 0, block.timestamp), 100e18);

        // The old positions' only exit is cancel, and it refunds exactly what was escrowed.
        uint256 daveBefore = usdc.balanceOf(dave);
        uint256 aliceBefore = rlusd.balanceOf(alice);
        vm.prank(dave);
        store.cancelQueue(buyId);
        vm.prank(alice);
        store.cancelQueue(sellId);
        assertEq(usdc.balanceOf(dave) - daveBefore, 500e6, "old buyer refunded in full");
        assertEq(rlusd.balanceOf(alice) - aliceBefore, 500e18, "old seller refunded in full");
    }

    // ============ Haircut after a relist: every line once, including the removed pool's ============

    function test_haircutAfterRelist_walksEachLineOnce() public {
        // Dave's 100 USDC stays in the removed spoke's line; Alice queues 100 USDC in the new spoke.
        uint256 oldId = _windDownAndQueueBuyer(dave, 100e6);
        _removeAndRelist();
        vm.prank(alice);
        store.swap(address(usdc), address(rlusd), 100e6, 0, 0, block.timestamp);
        uint256 newId = store.getUserQueuePositions(alice)[0];

        // The contract loses half its USDC to an external event. Books: 0 reserve + 200 escrow; actual: 100.
        usdc.burn(address(store), 100e6);

        // A budget of exactly two: the removed pool's line and the live line are distinct and each is
        // walked once. With asset-pair keys the live line was reached twice, squaring the ratio and
        // exhausting the budget.
        vm.startPrank(guardian);
        store.pausePool(0);
        uint256 removed = store.haircutEscrow(address(usdc), 2);
        vm.stopPrank();
        assertEq(removed, 100e6, "escrow reduced by exactly the shortfall");
        assertEq(_amount(oldId), 50e6, "removed pool's position shares the loss");
        assertEq(_amount(newId), 50e6, "live position shares the loss, pro rata once");
    }

    // ============ Relist as a hub asset: hub lines start empty, old positions stay cancellable ============

    function test_relistAsHubAsset_freshLines_oldPositionsUnreachable() public {
        // Alice sells RLUSD for USDT before wind-down; Dave buys RLUSD with USDC during it. Both queue.
        vm.prank(alice);
        store.swap(address(rlusd), address(usdt), 500e18, 0, 0, block.timestamp);
        uint256 sellId = store.getUserQueuePositions(alice)[0];
        uint256 buyId = _windDownAndQueueBuyer(dave, 500e6);

        vm.startPrank(governor);
        store.removePool(spoke);
        store.addHubAsset(address(rlusd), address(feed));
        vm.stopPrank();
        assertEq(store.assetPoolId(address(rlusd)), 0, "now a hub asset");

        // The same pairs are hub-to-hub lines in pool 0 now, and those start empty.
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0);
        assertEq(store.getQueueDepth(address(rlusd), address(usdt)), 0);

        // Hub liquidity in both assets fills a new swap instantly and leaves the old positions untouched.
        vm.startPrank(lp);
        store.deposit(0, address(rlusd), 1_000e18, block.timestamp);
        store.deposit(0, address(usdt), 1_000e6, block.timestamp);
        vm.stopPrank();
        vm.prank(carol);
        assertEq(store.swapExactInput(address(usdc), address(rlusd), 100e6, 0, block.timestamp), 100e18);
        assertEq(_amount(buyId), 500e6, "old buyer untouched");
        assertEq(_amount(sellId), 500e6, "old seller untouched");

        uint256 daveBefore = usdc.balanceOf(dave);
        uint256 aliceBefore = rlusd.balanceOf(alice);
        vm.prank(dave);
        store.cancelQueue(buyId);
        vm.prank(alice);
        store.cancelQueue(sellId);
        assertEq(usdc.balanceOf(dave) - daveBefore, 500e6, "old buyer refunded in full");
        assertEq(rlusd.balanceOf(alice) - aliceBefore, 500e18, "old seller refunded in full");
    }

    // ============ Haircut of a removed spoke's queued positions, before any relist ============

    function test_haircut_removedSpokeAsset_walksItsQueuedLine() public {
        // Alice sells RLUSD for USDC; the spoke has no USDC side, so she queues. The spoke is removed
        // with her position still queued, then the contract loses half its RLUSD.
        vm.prank(alice);
        store.swap(address(rlusd), address(usdc), 500e18, 0, 0, block.timestamp);
        uint256 id = store.getUserQueuePositions(alice)[0];
        vm.startPrank(governor);
        store.windDownSpoke(spoke);
        store.removePool(spoke);
        vm.stopPrank();
        rlusd.burn(address(store), 250e18);

        // The asset is unlisted and its removed pool stays paused, so the haircut runs without a pause
        // and reaches the queued position with a budget of exactly one.
        vm.prank(guardian);
        uint256 removed = store.haircutEscrow(address(rlusd), 1);
        assertEq(removed, 250e6, "escrow reduced by exactly the shortfall");
        assertEq(_amount(id), 250e6, "queued position in the removed pool shares the loss");
        assertFalse(store.isQueuePositionParked(id), "still queued, not parked");
    }

    // ============ The join event carries the pool ============

    function test_join_emitsThePoolItJoins() public {
        vm.expectEmit(false, true, false, true, address(store));
        emit QueueJoined(0, dave, address(usdc), address(rlusd), 900e6, spoke);
        vm.prank(dave);
        store.swap(address(usdc), address(rlusd), 900e6, 0, 0, block.timestamp);
    }
}
