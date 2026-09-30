// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../../src/DollarStore.sol";
import {DLRS} from "../../src/DLRS.sol";
import {QueueStorage} from "../../src/storage/QueueStorage.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {Handler} from "./Handler.sol";

/// @notice Core protocol invariants under randomized hub + spoke sequences, including the spoke being
///         retired and its asset listed again as a new pool.
///   1. DLRS backing conservation: total DLRS supply + sum of every spoke's dlrsReserve == sum of hub
///      reserves. (Queue escrow is NOT backing; spoke assets never back the hub.)
///   2. Solvency: the contract's token balance covers reserves + queue escrow for every asset.
///   3. Queue bookkeeping: every line's depth and count equal the positions that sit in it, across
///      every pool generation and the parked line; the per-asset escrow total equals the sum of
///      positions; each live position is listed under its owner exactly once.
/// @dev The handler never triggers the impairment paths (syncReserves / haircut), which intentionally
///      break backing conservation, so every invariant holds across the explored space. Escrow is summed
///      from positions, not from the pair-based views, because those report only the pool an asset is
///      currently listed in.
contract DollarStoreInvariants is StdInvariant, Test {
    DollarStore internal store;
    DLRS internal dlrs;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal rlusd; // 18dp spoke asset
    MockAggregatorV3 internal feed;
    Handler internal handler;

    uint16 internal spoke;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal upgrader = makeAddr("upgrader");

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        dlrs = DLRS(store.dlrs());

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        feed = new MockAggregatorV3(8, 1e8); // $1, fresh

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usdt), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0);
        vm.stopPrank();

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");

        handler = new Handler(store, dlrs, usdc, usdt, rlusd, spoke, address(feed), governor, actors);
        targetContract(address(handler));
    }

    /// @notice Every DLRS-denominated claim (wallet DLRS + each spoke generation's dlrsReserve) is
    ///         backed 1:1 by hub reserves. Queue escrow and spoke-asset reserves are NOT part of this.
    function invariant_dlrsBackingConservation() public view {
        uint256 hubReserves = store.getReserve(0, address(usdc)) + store.getReserve(0, address(usdt));
        uint256 dlrsClaims = dlrs.totalSupply();
        uint16[] memory spokes = handler.allSpokeIds();
        for (uint256 i; i < spokes.length; ++i) {
            dlrsClaims += store.getDlrsReserve(spokes[i]);
        }
        assertEq(dlrsClaims, hubReserves, "DLRS supply + spoke dlrsReserve must equal hub reserves");
    }

    /// @notice The contract holds at least reserves + queue escrow of every asset (never insolvent).
    function invariant_solvency() public view {
        _assertSolvent(usdc, 1); // 6dp -> scaling 1
        _assertSolvent(usdt, 1);
        _assertSolvent(rlusd, 1e12); // 18dp -> scaling 1e12
    }

    /// @notice The per-asset escrow total the contract keeps equals the sum of its positions.
    function invariant_escrowTotalMatchesPositions() public view {
        address[3] memory all = [address(usdc), address(usdt), address(rlusd)];
        for (uint256 i; i < all.length; ++i) {
            assertEq(_escrowTotal(all[i]), _positionEscrow(all[i]), "totalEscrowedByAsset == sum of positions");
        }
    }

    /// @notice Every line's depth and count equal the positions in it: both hub-to-hub lines, the four
    ///         hub<->spoke lines of every spoke generation, and the three parked lines.
    function invariant_linesMatchPositions() public view {
        _assertLine(QueueStorage.queueKey(address(usdc), address(usdt), 0), address(usdc), address(usdt), 0);
        _assertLine(QueueStorage.queueKey(address(usdt), address(usdc), 0), address(usdt), address(usdc), 0);
        uint16[] memory spokes = handler.allSpokeIds();
        for (uint256 i; i < spokes.length; ++i) {
            uint16 g = spokes[i];
            _assertLine(QueueStorage.queueKey(address(usdc), address(rlusd), g), address(usdc), address(rlusd), g);
            _assertLine(QueueStorage.queueKey(address(usdt), address(rlusd), g), address(usdt), address(rlusd), g);
            _assertLine(QueueStorage.queueKey(address(rlusd), address(usdc), g), address(rlusd), address(usdc), g);
            _assertLine(QueueStorage.queueKey(address(rlusd), address(usdt), g), address(rlusd), address(usdt), g);
        }
        address[3] memory all = [address(usdc), address(usdt), address(rlusd)];
        for (uint256 i; i < all.length; ++i) {
            _assertLine(QueueStorage.parkedKey(all[i]), all[i], address(0), 0);
        }
    }

    /// @notice A live position is listed under its owner exactly once; a removed one under nobody.
    function invariant_userPositionMembership() public view {
        uint256[] memory ids = handler.allPositionIds();
        address[] memory actors = handler.allActors();
        for (uint256 i; i < ids.length; ++i) {
            (address owner,,,,,) = store.getQueuePosition(ids[i]);
            for (uint256 a; a < actors.length; ++a) {
                uint256 seen;
                uint256[] memory mine = store.getUserQueuePositions(actors[a]);
                for (uint256 j; j < mine.length; ++j) {
                    if (mine[j] == ids[i]) seen++;
                }
                assertEq(seen, actors[a] == owner ? 1 : 0, "position listed under its owner exactly once");
            }
        }
    }

    /// @notice Guards the lifecycle coverage: the handler's actions can retire the spoke, list the asset
    ///         again, and leave live positions tagged with both generations. Without this, a change that
    ///         made those actions always fail would leave the invariants above passing vacuously.
    function test_handler_reachesASecondGeneration() public {
        handler.swapHubToSpoke(0, true, 500e6); // no RLUSD in the spoke: queued in generation 1
        handler.retireSpoke();
        handler.relistSpoke();
        handler.swapHubToSpoke(1, true, 500e6); // queued in generation 2

        assertEq(handler.removals(), 1, "spoke removed");
        assertEq(handler.relists(), 1, "asset listed again");
        uint16[] memory spokes = handler.allSpokeIds();
        assertEq(spokes.length, 2, "two generations");
        uint256[] memory ids = handler.allPositionIds();
        assertEq(ids.length, 2, "one live position per generation");
        (address owner1,,, uint256 amt1,, uint16 pool1) = store.getQueuePosition(ids[0]);
        (address owner2,,, uint256 amt2,, uint16 pool2) = store.getQueuePosition(ids[1]);
        assertTrue(owner1 != address(0) && owner2 != address(0), "both live");
        assertEq(amt1 + amt2, 1_000e6, "both fully queued");
        assertEq(pool1, spokes[0], "first position in the removed pool");
        assertEq(pool2, spokes[1], "second position in the new pool");
    }

    // ============ Helpers ============

    function _assertSolvent(MockERC20 asset, uint256 scaling) internal view {
        uint256 reserves;
        if (address(asset) == address(rlusd)) {
            uint16[] memory spokes = handler.allSpokeIds();
            for (uint256 i; i < spokes.length; ++i) {
                reserves += store.getReserve(spokes[i], address(asset));
            }
        } else {
            reserves = store.getReserve(0, address(asset));
        }
        uint256 accountedNative = (reserves + _positionEscrow(address(asset))) * scaling;
        assertGe(asset.balanceOf(address(store)), accountedNative, "balance covers reserves + escrow");
    }

    /// @dev Escrow of `asset` summed from every position the handler created that still exists.
    function _positionEscrow(address asset) internal view returns (uint256 total) {
        uint256[] memory ids = handler.allPositionIds();
        for (uint256 i; i < ids.length; ++i) {
            (address owner, address offer,, uint256 amt,,) = store.getQueuePosition(ids[i]);
            if (owner != address(0) && offer == asset) total += amt;
        }
    }

    /// @dev Depth and count of the line under `key` (read from storage) must equal the handler's
    ///      positions that sit in that line: same offer, same pool, and either the same want asset or,
    ///      for a parked line, the parked flag.
    function _assertLine(bytes32 key, address offer, address want, uint16 pool) internal view {
        uint256 depth;
        uint256 count;
        uint256[] memory ids = handler.allPositionIds();
        for (uint256 i; i < ids.length; ++i) {
            (address owner, address o, address w, uint256 amt,, uint16 p) = store.getQueuePosition(ids[i]);
            if (owner == address(0) || o != offer) continue;
            bool parked = store.isQueuePositionParked(ids[i]);
            bool inLine = want == address(0) ? parked : (!parked && w == want && p == pool);
            if (inLine) {
                depth += amt;
                count += 1;
            }
        }
        (uint256 storedCount, uint256 storedDepth) = _line(key);
        assertEq(storedCount, count, "line positionCount == positions in it");
        assertEq(storedDepth, depth, "line totalDepth == escrow of positions in it");
    }

    // Raw reads of QueueStorage.Layout: queues at slot +1 {head, tail, positionCount, totalDepth},
    // totalEscrowedByAsset at slot +4.
    function _line(bytes32 key) internal view returns (uint256 count, uint256 depth) {
        uint256 base = uint256(keccak256(abi.encode(key, uint256(QueueStorage.QUEUE_STORAGE_LOCATION) + 1)));
        count = uint256(vm.load(address(store), bytes32(base + 2)));
        depth = uint256(vm.load(address(store), bytes32(base + 3)));
    }

    function _escrowTotal(address asset) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(asset, uint256(QueueStorage.QUEUE_STORAGE_LOCATION) + 4));
        return uint256(vm.load(address(store), slot));
    }
}
