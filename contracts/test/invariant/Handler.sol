// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DollarStore} from "../../src/DollarStore.sol";
import {DLRS} from "../../src/DLRS.sol";
import {IDollarStore} from "../../src/interfaces/IDollarStore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Invariant handler: bounded, randomized hub + spoke actions against DollarStore. Reverts are
///         swallowed (fail_on_revert = false) so the fuzzer explores freely while the invariant
///         assertions run between calls. Hub assets are 6dp; spoke A's asset (rlusd) is 18dp and spoke
///         B's (xusd) is 6dp. Spoke B stays active so spoke-to-spoke swaps always have a live partner.
/// @dev Does NOT call impairment paths (syncReserves / haircut / deal) - those intentionally break
///      backing conservation and are covered by unit tests. The spoke lifecycle IS exercised: the spoke
///      can be wound down, retired, and its asset listed again as a new spoke, so positions of several
///      pool generations coexist.
contract Handler is Test {
    DollarStore internal store;
    DLRS internal dlrs;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal rlusd;
    address internal feed;
    address internal governor;
    uint16 internal spokeId; // the live spoke, or the last one if the asset is currently unlisted
    uint16[] internal spokeIds; // every spoke generation created so far

    address[] internal actors;
    uint256[] internal positionIds; // every queue position the handler created (one per queued swap)

    MockERC20 internal xusd;
    uint16 public spokeB;

    uint256 public removals; // successful removePool calls
    uint256 public relists; // successful createSpoke calls after a removal
    uint256 public s2sFills; // successful swapSpokeToSpoke calls
    uint256 public s2sSplits; // of which routed through more than one hub asset

    uint256 internal constant MAX_AMOUNT = 1_000_000e6; // hub assets (6dp)
    uint256 internal constant MAX_AMOUNT_18 = 1_000_000e18; // spoke asset (18dp)

    constructor(
        DollarStore _store,
        DLRS _dlrs,
        MockERC20 _usdc,
        MockERC20 _usdt,
        MockERC20 _rlusd,
        uint16 _spokeId,
        address _feed,
        address _governor,
        address[] memory _actors
    ) {
        store = _store;
        dlrs = _dlrs;
        usdc = _usdc;
        usdt = _usdt;
        rlusd = _rlusd;
        spokeId = _spokeId;
        spokeIds.push(_spokeId);
        feed = _feed;
        governor = _governor;
        actors = _actors;
    }

    /// @dev One-time setup. The fuzzer calls every external function, so a second call is ignored.
    function setSpokeB(MockERC20 _xusd, uint16 _spokeB) external {
        if (address(xusd) != address(0)) return;
        xusd = _xusd;
        spokeB = _spokeB;
    }

    function allSpokeIds() external view returns (uint16[] memory) {
        return spokeIds;
    }

    function allPositionIds() external view returns (uint256[] memory) {
        return positionIds;
    }

    function allActors() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pair(bool aFirst) internal view returns (MockERC20 a, MockERC20 b) {
        return aFirst ? (usdc, usdt) : (usdt, usdc);
    }

    function _trackQueued(address actor, uint256 queued) internal {
        if (queued > 0) {
            uint256[] memory ps = store.getUserQueuePositions(actor);
            if (ps.length > 0) positionIds.push(ps[ps.length - 1]);
        }
    }

    // ============ Hub actions ============

    function deposit(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 t = useUsdc ? usdc : usdt;
        amount = bound(amount, 0, MAX_AMOUNT);
        t.mint(actor, amount);
        vm.startPrank(actor);
        t.approve(address(store), amount);
        try store.deposit(0, address(t), amount, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 units) external {
        address actor = _actor(actorSeed);
        units = bound(units, 0, dlrs.balanceOf(actor));
        vm.startPrank(actor);
        try store.withdraw(0, units, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function swap(uint256 actorSeed, bool offerUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        (MockERC20 offer, MockERC20 want) = _pair(offerUsdc);
        amount = bound(amount, 0, MAX_AMOUNT);
        offer.mint(actor, amount);
        vm.startPrank(actor);
        offer.approve(address(store), amount);
        try store.swap(address(offer), address(want), amount, 0, 0, type(uint256).max) returns (
            uint256, uint256 queued
        ) {
            _trackQueued(actor, queued);
        } catch {}
        vm.stopPrank();
    }

    // ============ Spoke actions ============

    function depositSpoke(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, MAX_AMOUNT_18);
        rlusd.mint(actor, amount);
        vm.startPrank(actor);
        rlusd.approve(address(store), amount);
        try store.deposit(spokeId, address(rlusd), amount, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function fundSpoke(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 t = useUsdc ? usdc : usdt;
        amount = bound(amount, 0, MAX_AMOUNT);
        t.mint(actor, amount);
        vm.startPrank(actor);
        t.approve(address(store), amount);
        try store.deposit(spokeId, address(t), amount, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function withdrawSpoke(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        shares = bound(shares, 0, store.getReceiptShares(spokeId, actor));
        vm.startPrank(actor);
        try store.withdraw(spokeId, shares, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function swapHubToSpoke(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 offer = useUsdc ? usdc : usdt;
        amount = bound(amount, 0, MAX_AMOUNT);
        offer.mint(actor, amount);
        vm.startPrank(actor);
        offer.approve(address(store), amount);
        try store.swap(address(offer), address(rlusd), amount, 0, 0, type(uint256).max) returns (
            uint256, uint256 queued
        ) {
            _trackQueued(actor, queued);
        } catch {}
        vm.stopPrank();
    }

    function swapSpokeToHub(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 want = useUsdc ? usdc : usdt;
        amount = bound(amount, 0, MAX_AMOUNT_18);
        rlusd.mint(actor, amount);
        vm.startPrank(actor);
        rlusd.approve(address(store), amount);
        try store.swap(address(rlusd), address(want), amount, 0, 0, type(uint256).max) returns (
            uint256, uint256 queued
        ) {
            _trackQueued(actor, queued);
        } catch {}
        vm.stopPrank();
    }

    // ============ Spoke B and spoke-to-spoke ============

    function depositSpokeB(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, MAX_AMOUNT);
        xusd.mint(actor, amount);
        vm.startPrank(actor);
        xusd.approve(address(store), amount);
        try store.deposit(spokeB, address(xusd), amount, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function fundSpokeB(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 t = useUsdc ? usdc : usdt;
        amount = bound(amount, 0, MAX_AMOUNT);
        t.mint(actor, amount);
        vm.startPrank(actor);
        t.approve(address(store), amount);
        try store.deposit(spokeB, address(t), amount, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    function withdrawSpokeB(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        shares = bound(shares, 0, store.getReceiptShares(spokeB, actor));
        vm.startPrank(actor);
        try store.withdraw(spokeB, shares, type(uint256).max) {} catch {}
        vm.stopPrank();
    }

    /// @dev Hub <-> spoke B swaps, in either direction, so spoke-to-spoke legs meet queued positions.
    function swapHubSpokeB(uint256 actorSeed, bool useUsdc, bool toSpoke, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 hub = useUsdc ? usdc : usdt;
        (MockERC20 offer, MockERC20 want) = toSpoke ? (hub, xusd) : (xusd, hub);
        amount = bound(amount, 0, MAX_AMOUNT);
        offer.mint(actor, amount);
        vm.startPrank(actor);
        offer.approve(address(store), amount);
        try store.swap(address(offer), address(want), amount, 0, 0, type(uint256).max) returns (
            uint256, uint256 queued
        ) {
            _trackQueued(actor, queued);
        } catch {}
        vm.stopPrank();
    }

    /// @dev Spoke A <-> spoke B through one of six hub-asset lists: each single asset, both orders of
    ///      the split, and each asset repeated.
    function swapSpokeToSpoke(uint256 actorSeed, bool aToB, uint256 viaSeed, uint256 amount) external {
        if (!store.isAssetListed(address(rlusd))) this.relistSpoke(); // keep a partner for spoke B
        address actor = _actor(actorSeed);
        (MockERC20 offer, MockERC20 want) = aToB ? (rlusd, xusd) : (xusd, rlusd);
        uint256 v = viaSeed % 6;
        address[] memory via = new address[](v < 2 ? 1 : 2);
        via[0] = v == 1 || v == 3 || v == 5 ? address(usdt) : address(usdc);
        if (via.length == 2) via[1] = v == 2 || v == 5 ? address(usdt) : address(usdc);
        // Fill-or-revert, so size to what both spokes can fill from reserves; queues and the per-asset
        // hub limit can still make it revert.
        (uint16 from, uint16 to) = aToB ? (spokeId, spokeB) : (spokeB, spokeId);
        uint256 claim = store.getDlrsReserve(from);
        uint256 floor = store.getMinDlrsReserve(from);
        uint256 room = claim > floor ? claim - floor : 0;
        uint256 held = store.getReserve(to, address(want));
        if (held < room) room = held;
        if (via.length == 1 && store.getReserve(0, via[0]) < room) room = store.getReserve(0, via[0]);
        uint256 unit = aToB ? 1e12 : 1;
        amount = bound(amount, unit, (room == 0 ? MAX_AMOUNT : room) * unit);
        offer.mint(actor, amount);
        vm.startPrank(actor);
        offer.approve(address(store), amount);
        vm.recordLogs();
        try store.swapSpokeToSpoke(address(offer), address(want), via, amount, type(uint256).max) {
            s2sFills += 1;
            if (_routedCount() > 1) s2sSplits += 1;
        } catch {}
        vm.stopPrank();
    }

    function _routedCount() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IDollarStore.SpokeSwapRouted.selector) n++;
        }
    }

    // ============ Spoke lifecycle ============

    /// @dev Acts on one call in four, so most runs keep spoke A active long enough to trade.
    function windDown(uint256 seed) external {
        if (seed % 4 != 0) return;
        vm.prank(governor);
        try store.windDownSpoke(spokeId) {} catch {}
    }

    /// @dev Every LP redeems in full, then governance removes the pool. Any step may fail; removal
    ///      succeeds only when the spoke is fully drained, and dust from rounding can keep it alive.
    ///      Acts on one call in four, like windDown.
    function retireSpoke(uint256 seed) external {
        if (seed % 4 != 0) return;
        for (uint256 i; i < actors.length; ++i) {
            uint256 shares = store.getReceiptShares(spokeId, actors[i]);
            if (shares == 0) continue;
            vm.prank(actors[i]);
            try store.withdraw(spokeId, shares, type(uint256).max) {} catch {}
        }
        vm.prank(governor);
        try store.removePool(spokeId) {
            removals += 1;
        } catch {}
    }

    /// @dev Lists the spoke asset again once its previous pool is gone; the new pool becomes the target
    ///      of every spoke action from here on.
    function relistSpoke() external {
        if (store.isAssetListed(address(rlusd))) return;
        vm.prank(governor);
        try store.createSpoke(address(rlusd), feed, 0) returns (uint16 id) {
            spokeId = id;
            spokeIds.push(id);
            relists += 1;
        } catch {}
    }

    // ============ Shared: cancel + process ============

    function cancel(uint256 posSeed) external {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[posSeed % positionIds.length];
        (address owner,,,,,) = store.getQueuePosition(id);
        if (owner == address(0)) return; // already filled/cancelled
        vm.startPrank(owner);
        try store.cancelQueue(id) {} catch {}
        vm.stopPrank();
    }

    function process(uint256 routeSeed, uint256 maxPositions) external {
        maxPositions = bound(maxPositions, 0, 50);
        address offer;
        address want;
        uint256 r = routeSeed % 10;
        if (r == 0) (offer, want) = (address(usdc), address(usdt));
        else if (r == 1) (offer, want) = (address(usdt), address(usdc));
        else if (r == 2) (offer, want) = (address(rlusd), address(usdc));
        else if (r == 3) (offer, want) = (address(usdc), address(rlusd));
        else if (r == 4) (offer, want) = (address(rlusd), address(usdt));
        else if (r == 5) (offer, want) = (address(usdt), address(rlusd));
        else if (r == 6) (offer, want) = (address(xusd), address(usdc));
        else if (r == 7) (offer, want) = (address(usdc), address(xusd));
        else if (r == 8) (offer, want) = (address(xusd), address(usdt));
        else (offer, want) = (address(usdt), address(xusd));
        try store.processQueue(offer, want, maxPositions) {} catch {}
    }
}
