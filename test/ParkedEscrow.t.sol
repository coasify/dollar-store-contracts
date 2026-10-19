// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {DLRS} from "../src/DLRS.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @dev Token that re-enters cancelQueue on the SAME position while the store is paying it out. Proves
///      the send-before-state ordering in cancelPosition cannot be exploited: the re-entrant call trips
///      the guard, which makes the token's own transfer revert, which parks the position unpaid.
contract MockReenterCancelERC20 is ERC20 {
    address public store;
    uint256 public targetId;
    bool public armed;
    uint256 public reentries;

    constructor() ERC20("Evil", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address store_, uint256 id) external {
        store = store_;
        targetId = id;
        armed = true;
    }

    /// @dev Explicit, because `armed = false` inside _update is rolled back when the transfer reverts.
    function disarm() external {
        armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == store && to != store) {
            armed = false;
            reentries += 1;
            IDollarStore(store).cancelQueue(targetId); // reverts on the guard -> this transfer reverts
        }
    }
}

/// @notice When a transfer to a queued owner fails the position is parked: lifted out of its queue so
///         others can be paid, escrow untouched, cancellable later in the asset it was deposited as. A
///         parked position holds no claim on any pool, so it cannot exit in another asset and cannot
///         hold a spoke open.
contract ParkedEscrowTest is Test {
    DollarStore internal store;
    DLRS internal dlrs;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice"); // the frozen seller
    address internal bob = makeAddr("bob"); // queued behind alice
    address internal carol = makeAddr("carol"); // LP
    address internal dana = makeAddr("dana"); // LP who funds the spoke

    MockBlacklistERC20 internal usdc; // 6dp hub
    MockBlacklistERC20 internal usds; // 18dp hub, blocks no one in these tests
    MockBlacklistERC20 internal pyusd; // 6dp spoke asset
    MockAggregatorV3 internal feed;

    uint16 internal spoke;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser, Pausers.one(pauser)));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        dlrs = DLRS(store.dlrs());

        usdc = new MockBlacklistERC20("USD Coin", "USDC", 6);
        usds = new MockBlacklistERC20("USDS", "USDS", 18);
        pyusd = new MockBlacklistERC20("PYUSD", "PYUSD", 6);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usds), address(feed));
        spoke = store.createSpoke(address(pyusd), address(feed), 0, 0);
        vm.stopPrank();

        address[4] memory who = [alice, bob, carol, dana];
        for (uint256 i; i < 4; i++) {
            usdc.mint(who[i], 1_000_000e6);
            usds.mint(who[i], 1_000_000e18);
            pyusd.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            usdc.approve(address(store), type(uint256).max);
            usds.approve(address(store), type(uint256).max);
            pyusd.approve(address(store), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _sellPyusdForUsdc(address who, uint256 amt) internal returns (uint256 id) {
        vm.prank(who);
        (,, uint256 queued,) = store.swapOrQueue(address(pyusd), address(usdc), amt, 0, block.timestamp);
        assertEq(queued, amt, "queued: spoke has no claim to pay from");
        uint256[] memory ids = store.getUserQueuePositions(who);
        id = ids[ids.length - 1];
    }

    /// @dev Block `who` on USDC, then have Dana fund the spoke with USDC: settlement reaches `who`'s
    ///      PYUSD -> USDC position, the USDC transfer fails, and the position is parked.
    function _parkViaFunding(address who, uint256 usdcAmt) internal {
        usdc.setBlocked(who, true);
        vm.prank(dana);
        store.deposit(spoke, address(usdc), usdcAmt, block.timestamp);
    }

    // ============ Blocked seller: the line advances past her, her escrow stays hers ============

    function test_frozenSeller_isParked_lineAdvances_noShares() public {
        // Carol LPs 400 PYUSD. Alice then Bob queue PYUSD -> USDC; nothing can pay them yet.
        vm.prank(carol);
        store.deposit(spoke, address(pyusd), 400e6, block.timestamp);
        uint256 aliceId = _sellPyusdForUsdc(alice, 100e6);
        _sellPyusdForUsdc(bob, 500e6); // min order size once the line is non-empty

        // The USDC issuer blocks Alice and Dana funds 700 USDC. Settlement reaches Alice first, the USDC
        // transfer reverts, she is parked, and Bob behind her is paid in full in the same call.
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        _parkViaFunding(alice, 700e6);

        assertTrue(store.isQueuePositionParked(aliceId), "alice parked");
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, 500e6, "bob paid past alice");
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 0, "line empty");
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 100e6, "alice's escrow on the parked line");

        // The position itself is untouched: still hers, same asset and amount, original want asset kept.
        assertEq(store.getUserQueuePositions(alice).length, 1, "still listed under alice");
        (address owner, address offer, address want, uint256 amt,,) = store.getQueuePosition(aliceId);
        assertEq(owner, alice);
        assertEq(offer, address(pyusd));
        assertEq(want, address(usdc), "original want kept for the UI");
        assertEq(amt, 100e6);
        // Parked escrow is still accounted, so the governor cannot sweep it.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.NoExcessTokens.selector, address(pyusd)));
        store.rescueTokens(address(pyusd), governor);

        // Nothing about Alice touched the pool: no shares, her PYUSD is not in the reserve, claim only
        // dropped by what Bob was paid.
        assertEq(store.getReceiptShares(spoke, alice), 0, "alice holds no shares");
        assertEq(dlrs.balanceOf(alice), 0, "alice holds no DLRS");
        assertEq(store.getReserve(spoke, address(pyusd)), 900e6, "carol 400 + bob 500, NOT alice's 100");
        assertEq(store.getDlrsReserve(spoke), 200e6, "dana 700 - bob 500");
        assertEq(store.getReceiptTotalShares(spoke), 1_100e6, "carol 400 + dana 700");

        // Alice has no path to any hub asset: she holds no shares and no DLRS.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, 1, 0));
        store.withdraw(spoke, 1, block.timestamp);

        // Cancel while blocked on USDC: the PYUSD transfer succeeds, so she gets her escrow back as PYUSD.
        uint256 pyBefore = pyusd.balanceOf(alice);
        vm.prank(alice);
        store.cancelQueue(aliceId);
        assertEq(pyusd.balanceOf(alice) - pyBefore, 100e6, "escrow returned as PYUSD");
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 0);
    }

    // ============ Blocked on both assets: no exit in any asset until the escrow asset is unblocked ============

    function test_twoIssuerFreeze_noExitInAnyOtherAsset_spokeStillRetirable() public {
        vm.prank(carol);
        store.deposit(spoke, address(pyusd), 400e6, block.timestamp);
        uint256 aliceId = _sellPyusdForUsdc(alice, 100e6);

        pyusd.setBlocked(alice, true);
        _parkViaFunding(alice, 100e6);
        assertTrue(store.isQueuePositionParked(aliceId));

        // No claim on the pool, so no way to withdraw anything from it.
        assertEq(store.getReceiptShares(spoke, alice), 0);
        assertEq(dlrs.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, 1, 0));
        store.withdraw(spoke, 1, block.timestamp);

        // Cancel fails while PYUSD is blocked to her: position stays parked, escrow intact.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.EscrowTransferFailed.selector, aliceId));
        store.cancelQueue(aliceId);
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 100e6, "escrow still parked");

        // Everyone else can leave and the spoke can be killed regardless of Alice's parked escrow.
        vm.prank(carol);
        store.withdraw(spoke, 400e6, block.timestamp);
        vm.prank(dana);
        store.withdraw(spoke, 100e6, block.timestamp);
        assertEq(store.getReserve(spoke, address(pyusd)), 0);
        assertEq(store.getDlrsReserve(spoke), 0);
        vm.startPrank(governor);
        store.windDownSpoke(spoke);
        store.removePool(spoke);
        vm.stopPrank();
        assertEq(store.getPoolStatus(spoke), 2, "killed with alice still parked");

        // Her escrow stays accounted after removal: the governor can sweep a surplus, never the escrow.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.NoExcessTokens.selector, address(pyusd)));
        store.rescueTokens(address(pyusd), governor);
        pyusd.mint(address(store), 7e6);
        vm.prank(governor);
        store.rescueTokens(address(pyusd), governor);
        assertEq(pyusd.balanceOf(governor), 7e6, "only the surplus");
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 100e6, "escrow untouched");

        // Once PYUSD is unblocked, cancel returns the PYUSD she deposited.
        pyusd.setBlocked(alice, false);
        uint256 pyBefore = pyusd.balanceOf(alice);
        vm.prank(alice);
        store.cancelQueue(aliceId);
        assertEq(pyusd.balanceOf(alice) - pyBefore, 100e6);
        assertEq(store.getUserQueuePositions(alice).length, 0);
    }

    // ============ An owner's parked positions cost nobody else anything ============

    /// @dev Alice, blocked on USDC, queues one unit of PYUSD -> USDC; Bob's opposite swap fails to pay
    ///      her, which parks it. Bob's own remainder queues and he cancels it, leaving both lines empty.
    function _parkOneUnit() internal {
        vm.prank(alice);
        store.swapOrQueue(address(pyusd), address(usdc), 1, 0, block.timestamp);
        vm.prank(bob);
        store.swapOrQueue(address(usdc), address(pyusd), 1, 0, block.timestamp);
        uint256 bobId = store.getUserQueuePositions(bob)[0];
        vm.prank(bob);
        store.cancelQueue(bobId);
    }

    /// @dev Gas of the deposit that pays Alice's USDS -> PYUSD position in full, with `parked` positions
    ///      of hers on the parked line. Storage is cooled first so every slot read is priced as on chain.
    function _fillGasWithParked(uint256 parked) internal returns (uint256 gasUsed) {
        for (uint256 i; i < parked; i++) {
            _parkOneUnit();
        }
        vm.prank(alice);
        store.swapOrQueue(address(usds), address(pyusd), 100e18, 0, block.timestamp);
        assertEq(store.getUserQueuePositions(alice).length, parked + 1);

        uint256 pyBefore = pyusd.balanceOf(alice);
        vm.cool(address(store));
        vm.prank(dana);
        uint256 g = gasleft();
        store.deposit(spoke, address(pyusd), 500e6, block.timestamp);
        gasUsed = g - gasleft();

        assertEq(pyusd.balanceOf(alice) - pyBefore, 100e6, "alice paid in full");
        assertEq(store.getUserQueuePositions(alice).length, parked, "only the parked positions remain");
    }

    /// @notice Paying a position in full costs the same however many parked positions its owner holds.
    function test_fill_costDoesNotGrowWithOwnersParkedPositions() public {
        usdc.setBlocked(alice, true);
        uint256 snap = vm.snapshotState();
        uint256 one = _fillGasWithParked(1);
        vm.revertToState(snap);
        uint256 many = _fillGasWithParked(40);
        assertApproxEqAbs(many, one, 5_000, "no per-parked-position cost");
    }

    /// @notice Removing positions in any order keeps the owner's list exact: a parked one from the front,
    ///         then the queued one that took its place by a fill, then the last parked one.
    function test_remove_keepsOwnersListExact_parkedAndQueuedInAnyOrder() public {
        usdc.setBlocked(alice, true);
        _parkOneUnit();
        _parkOneUnit();
        vm.prank(alice);
        store.swapOrQueue(address(usds), address(pyusd), 100e18, 0, block.timestamp);
        uint256[] memory ids = store.getUserQueuePositions(alice);
        assertEq(ids.length, 3);
        (uint256 parkedA, uint256 parkedB, uint256 queued) = (ids[0], ids[1], ids[2]);

        // Cancel the first parked position: the queued one takes its place at the front.
        vm.prank(alice);
        store.cancelQueue(parkedA);
        ids = store.getUserQueuePositions(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], queued);
        assertEq(ids[1], parkedB);

        // A deposit pays the queued position in full: the remaining parked one moves to the front.
        vm.prank(dana);
        store.deposit(spoke, address(pyusd), 500e6, block.timestamp);
        ids = store.getUserQueuePositions(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], parkedB);

        vm.prank(alice);
        store.cancelQueue(parkedB);
        assertEq(store.getUserQueuePositions(alice).length, 0);
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 0, "parked line empty");
    }

    /// @notice The parked line takes no orders: its length does not change the minimum reported for it,
    ///         while its depth is still reported.
    function test_minimumOrderSize_parkedLine_isTheBaseMinimum() public {
        usdc.setBlocked(alice, true);
        for (uint256 i; i < 25; i++) {
            _parkOneUnit();
        }
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 25, "25 parked");
        assertEq(store.getMinimumOrderSize(address(pyusd), address(0)), 500e6, "base minimum");
    }

    // ============ The issuer of the asset being paid decides; the escrowed asset's issuer is not asked ============

    /// @notice A queued owner blocked on the asset they escrowed, but not on the asset they will receive,
    ///         is paid on settlement and is not parked. Only a failed payout transfer parks.
    function test_settle_payoutIssuerDecides_offerAssetBlockDoesNotPark() public {
        // Alice queues USDC -> PYUSD; the spoke holds no PYUSD, so nothing can pay her yet.
        vm.prank(alice);
        (,, uint256 queued,) = store.swapOrQueue(address(usdc), address(pyusd), 100e6, 0, block.timestamp);
        assertEq(queued, 100e6);
        uint256 id = store.getUserQueuePositions(alice)[0];

        // She is then blocked on USDC, the asset she escrowed. PYUSD still transfers to her.
        usdc.setBlocked(alice, true);
        vm.prank(dana);
        vm.expectRevert(bytes("blocked"));
        usdc.transfer(alice, 1);

        // Dana's PYUSD deposit settles the line: the PYUSD payout succeeds, so Alice is paid in full.
        uint256 pyBefore = pyusd.balanceOf(alice);
        vm.prank(dana);
        store.deposit(spoke, address(pyusd), 500e6, block.timestamp);

        assertEq(pyusd.balanceOf(alice) - pyBefore, 100e6, "paid in the asset she wanted");
        assertFalse(store.isQueuePositionParked(id));
        assertEq(store.getUserQueuePositions(alice).length, 0, "position settled and removed");
        assertEq(store.getQueueDepth(address(usdc), address(0)), 0, "nothing parked");
        assertEq(store.getReserve(0, address(usdc)), 100e6, "her USDC escrow entered hub reserves");
        assertEq(store.getDlrsReserve(spoke), 100e6, "spoke claim grew by the fill");
        assertEq(store.getReserve(spoke, address(pyusd)), 400e6, "dana 500 - alice 100");
    }

    // ============ After removal, parked escrow of the spoke asset still shares a loss pro-rata ============

    function test_haircut_afterRemoval_parkedEscrowSharesTheLoss() public {
        uint256 aliceId = _sellPyusdForUsdc(alice, 100e6);
        uint256 bobId = _sellPyusdForUsdc(bob, 500e6);
        usdc.setBlocked(bob, true);
        _parkViaFunding(alice, 600e6); // parks both
        assertTrue(store.isQueuePositionParked(aliceId) && store.isQueuePositionParked(bobId));

        // Dana leaves and the spoke is removed with 600 PYUSD still parked.
        vm.prank(dana);
        store.withdraw(spoke, 600e6, block.timestamp);
        vm.startPrank(governor);
        store.windDownSpoke(spoke);
        store.removePool(spoke);
        vm.stopPrank();

        // The contract loses half its PYUSD. The asset is unlisted, but its escrow is still haircuttable.
        deal(address(pyusd), address(store), 300e6);
        vm.prank(guardian);
        uint256 removed = store.haircutEscrow(address(pyusd), 10);
        assertEq(removed, 300e6);
        (,,, uint256 a,,) = store.getQueuePosition(aliceId);
        (,,, uint256 b,,) = store.getQueuePosition(bobId);
        assertEq(a, 50e6);
        assertEq(b, 250e6);

        // Both can still cancel, each for their reduced share.
        uint256 before = pyusd.balanceOf(alice);
        vm.prank(alice);
        store.cancelQueue(aliceId);
        assertEq(pyusd.balanceOf(alice) - before, 50e6);
        before = pyusd.balanceOf(bob);
        vm.prank(bob);
        store.cancelQueue(bobId);
        assertEq(pyusd.balanceOf(bob) - before, 250e6);
        assertEq(pyusd.balanceOf(address(store)), 0);
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 0, "parked depth cleared");
    }

    // ============ park() is idempotent; the parked line shares a haircut like any other line ============

    /// @notice Cancelling a parked position while still frozen reverts BEFORE touching state, and the
    ///         parked lane's bookkeeping is unchanged afterwards: no double-unlink, no duplicate entry. A
    ///         haircut then walks exactly the two parked positions and writes each down pro-rata.
    function test_park_isIdempotent_haircutWalksParkedLine() public {
        uint256 id = _sellPyusdForUsdc(alice, 100e6);
        uint256 id2 = _sellPyusdForUsdc(bob, 500e6);
        pyusd.setBlocked(alice, true);
        pyusd.setBlocked(bob, true);

        // Both cancel while frozen on PYUSD: both get parked, lane holds 600 in two entries.
        vm.prank(alice);
        store.cancelQueue(id);
        vm.prank(bob);
        store.cancelQueue(id2);
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 600e6);
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 0);

        // Repeated failed cancels revert and change nothing.
        for (uint256 i; i < 3; i++) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IDollarStore.EscrowTransferFailed.selector, id));
            store.cancelQueue(id);
        }
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 600e6, "lane depth unchanged");

        // The lane is still a well-formed list: a haircut walks exactly two positions.
        deal(address(pyusd), address(store), 300e6);
        vm.prank(pauser);
        store.pausePool(spoke);
        vm.prank(guardian);
        uint256 removed = store.haircutEscrow(address(pyusd), 2); // budget of exactly 2
        assertEq(removed, 300e6);
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 300e6, "parked depth written down too");
        (,,, uint256 a,,) = store.getQueuePosition(id);
        (,,, uint256 b,,) = store.getQueuePosition(id2);
        assertEq(a, 50e6);
        assertEq(b, 250e6);
    }

    // ============ Reentrancy: send-before-state in cancel cannot double-pay ============

    function test_cancel_reentrantTokenCannotDoublePay_positionIsParkedInstead() public {
        MockReenterCancelERC20 evil = new MockReenterCancelERC20();
        vm.prank(governor);
        store.addHubAsset(address(evil), address(feed));
        evil.mint(alice, 1_000e6);
        vm.startPrank(alice);
        evil.approve(address(store), type(uint256).max);
        store.swapOrQueue(address(evil), address(usds), 1_000e6, 0, block.timestamp); // no USDS: queued
        vm.stopPrank();
        uint256 id = store.getUserQueuePositions(alice)[0];

        // The escrow token will re-enter cancelQueue(id) while the store is paying alice back. The
        // re-entrant call hits the guard and reverts; that reverts the token's transfer; the outer
        // cancel sees a failed transfer and parks. (The token's own counters are rolled back with the
        // transfer, so the re-entry is witnessed via expectCall rather than the mock's state.)
        evil.arm(address(store), id);
        uint256 before = evil.balanceOf(alice);
        // Counted over the whole test: this outer cancel + the re-entrant one + the final clean cancel below.
        // Without the re-entry the count would be 2.
        vm.expectCall(address(store), abi.encodeCall(IDollarStore.cancelQueue, (id)), 3);
        vm.prank(alice);
        store.cancelQueue(id); // does NOT revert: the failed transfer is handled by parking

        assertEq(evil.balanceOf(alice), before, "alice was paid nothing, let alone twice");
        assertTrue(store.isQueuePositionParked(id), "position parked, escrow intact");
        assertEq(store.getQueueDepth(address(evil), address(0)), 1_000e6);
        assertEq(evil.balanceOf(address(store)), 1_000e6, "store still holds the escrow");

        // With the attack disarmed, a plain cancel pays her exactly once.
        evil.disarm();
        vm.prank(alice);
        store.cancelQueue(id);
        assertEq(evil.balanceOf(alice), before + 1_000e6);
        assertEq(store.getUserQueuePositions(alice).length, 0);
    }
}
