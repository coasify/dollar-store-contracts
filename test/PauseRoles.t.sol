// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice Pausing and unpausing as their own roles: any listed pauser pauses alone and can do
///         nothing else; only the unpauser lifts a pause and sets who may pause; the guardian and
///         the governor can do neither.
contract PauseRolesTest is Test {
    DollarStore internal store;

    address internal upgrader = makeAddr("upgrader");
    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal unpauser = makeAddr("unpauser");
    address internal pauserA = makeAddr("pauserA");
    address internal pauserB = makeAddr("pauserB");
    address internal alice = makeAddr("alice");

    MockERC20 internal usdc;
    MockAggregatorV3 internal feed;

    function setUp() public {
        store = _deploy(unpauser, _list(pauserA, pauserB));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.addHubAsset(address(usdc), address(feed));
    }

    function _deploy(address unpauser_, address[] memory pausers_) internal returns (DollarStore) {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser_, pausers_));
        return DollarStore(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _list(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _pauseAll(address who) internal {
        vm.startPrank(who);
        store.pause();
        store.pausePool(0);
        store.pauseDeposits(address(usdc));
        vm.stopPrank();
    }

    function _unpauseAll() internal {
        vm.startPrank(unpauser);
        store.unpause();
        store.unpausePool(0);
        store.unpauseDeposits(address(usdc));
        vm.stopPrank();
    }

    function _assertAllPaused(bool paused) internal view {
        assertEq(store.paused(), paused, "global");
        assertEq(store.isPoolPaused(0), paused, "pool");
        assertEq(store.isDepositPaused(address(usdc)), paused, "asset");
    }

    // ============ Initial state ============

    function test_initialize_setsUnpauserAndPausers() public view {
        assertEq(store.unpauser(), unpauser, "unpauser");
        assertTrue(store.isPauser(pauserA), "pauser A");
        assertTrue(store.isPauser(pauserB), "pauser B");
        assertFalse(store.isPauser(guardian), "guardian is not a pauser");
        assertFalse(store.isPauser(governor), "governor is not a pauser");
        assertFalse(store.isPauser(unpauser), "unpauser is not a pauser");
    }

    function test_initialize_emitsPauserSetForEach() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser, _list(pauserA, pauserB)));
        vm.expectEmit(true, false, false, true);
        emit IDollarStore.PauserSet(pauserA, true);
        vm.expectEmit(true, false, false, true);
        emit IDollarStore.PauserSet(pauserB, true);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnZeroUnpauser() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, address(0), _list(pauserA, pauserB)));
        vm.expectRevert(IDollarStore.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnZeroPauser() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize, (upgrader, governor, guardian, unpauser, _list(pauserA, address(0)))
        );
        vm.expectRevert(IDollarStore.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @notice The contract accepts an empty list; the governance deploy script is what refuses it.
    function test_initialize_emptyPauserList_nobodyCanPause() public {
        DollarStore bare = _deploy(unpauser, new address[](0));
        vm.prank(pauserA);
        vm.expectRevert(IDollarStore.OnlyPauser.selector);
        bare.pause();
    }

    // ============ Pausing ============

    function test_eachPauser_pausesAlone_allThreeScopes() public {
        _pauseAll(pauserA);
        _assertAllPaused(true);

        _unpauseAll();
        _assertAllPaused(false);

        _pauseAll(pauserB);
        _assertAllPaused(true);
    }

    function test_nonPausers_cannotPause() public {
        address[4] memory callers = [guardian, governor, unpauser, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IDollarStore.OnlyPauser.selector);
            store.pause();
            vm.expectRevert(IDollarStore.OnlyPauser.selector);
            store.pausePool(0);
            vm.expectRevert(IDollarStore.OnlyPauser.selector);
            store.pauseDeposits(address(usdc));
            vm.stopPrank();
        }
        _assertAllPaused(false);
    }

    // ============ Unpausing ============

    function test_onlyUnpauser_unpauses_allThreeScopes() public {
        _pauseAll(pauserA);

        address[5] memory callers = [pauserA, pauserB, guardian, governor, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
            store.unpause();
            vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
            store.unpausePool(0);
            vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
            store.unpauseDeposits(address(usdc));
            vm.stopPrank();
        }
        _assertAllPaused(true);

        _unpauseAll();
        _assertAllPaused(false);
    }

    // ============ Managing the pauser list ============

    function test_setPauser_addsAndRemoves() public {
        vm.expectEmit(true, false, false, true);
        emit IDollarStore.PauserSet(alice, true);
        vm.prank(unpauser);
        store.setPauser(alice, true);
        assertTrue(store.isPauser(alice), "added");

        vm.prank(alice);
        store.pause();
        assertTrue(store.paused(), "new pauser pauses");

        vm.expectEmit(true, false, false, true);
        emit IDollarStore.PauserSet(alice, false);
        vm.prank(unpauser);
        store.setPauser(alice, false);
        assertFalse(store.isPauser(alice), "removed");
    }

    function test_removedPauser_cannotPause_othersStillCan() public {
        vm.prank(unpauser);
        store.setPauser(pauserA, false);

        vm.prank(pauserA);
        vm.expectRevert(IDollarStore.OnlyPauser.selector);
        store.pause();

        vm.prank(pauserB);
        store.pause();
        assertTrue(store.paused(), "the other pauser is unaffected");
    }

    /// @notice A pause outlives the pauser that set it: removing a pauser is not an unpause.
    function test_removingPauser_doesNotLiftItsPause() public {
        _pauseAll(pauserA);
        vm.prank(unpauser);
        store.setPauser(pauserA, false);
        _assertAllPaused(true);
    }

    /// @notice A pauser that keeps pausing is stopped by removing it, with no delay.
    function test_repeatPauser_isStoppedByRemoval() public {
        vm.prank(pauserA);
        store.pause();
        vm.startPrank(unpauser);
        store.setPauser(pauserA, false);
        store.unpause();
        vm.stopPrank();

        vm.prank(pauserA);
        vm.expectRevert(IDollarStore.OnlyPauser.selector);
        store.pause();
        assertFalse(store.paused(), "stays unpaused");
    }

    function test_setPauser_onlyUnpauser() public {
        address[5] memory callers = [pauserA, guardian, governor, upgrader, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
            store.setPauser(alice, true);
        }
        assertFalse(store.isPauser(alice), "not added");

        // A pauser cannot remove another pauser either.
        vm.prank(pauserA);
        vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
        store.setPauser(pauserB, false);
        assertTrue(store.isPauser(pauserB), "still listed");
    }

    function test_setPauser_revertsOnZeroAddress() public {
        vm.prank(unpauser);
        vm.expectRevert(IDollarStore.ZeroAddress.selector);
        store.setPauser(address(0), true);
    }

    /// @notice The unpauser has no pause power of its own, but it sets the list, so it can list itself.
    function test_unpauser_canListItself() public {
        vm.startPrank(unpauser);
        vm.expectRevert(IDollarStore.OnlyPauser.selector);
        store.pause();
        store.setPauser(unpauser, true);
        store.pause();
        vm.stopPrank();
        assertTrue(store.paused(), "paused once listed");
    }

    // ============ Replacing the unpauser ============

    function test_setUnpauser_onlyGovernor() public {
        address[5] memory callers = [unpauser, pauserA, guardian, upgrader, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IDollarStore.OnlyGovernor.selector);
            store.setUnpauser(alice);
        }
        assertEq(store.unpauser(), unpauser, "unchanged");
    }

    function test_setUnpauser_movesTheRole() public {
        vm.prank(pauserA);
        store.pause();

        vm.expectEmit(true, true, false, true);
        emit IDollarStore.UnpauserSet(unpauser, alice);
        vm.prank(governor);
        store.setUnpauser(alice);
        assertEq(store.unpauser(), alice, "replaced");

        vm.startPrank(unpauser);
        vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
        store.unpause();
        vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
        store.setPauser(pauserB, false);
        vm.stopPrank();

        vm.startPrank(alice);
        store.unpause();
        store.setPauser(pauserB, false);
        vm.stopPrank();
        assertFalse(store.paused(), "new unpauser lifts the pause");
        assertFalse(store.isPauser(pauserB), "new unpauser sets the list");
    }

    function test_setUnpauser_revertsOnZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(IDollarStore.ZeroAddress.selector);
        store.setUnpauser(address(0));
    }

    // ============ What the guardian keeps, and what stays open ============

    function test_guardian_stillLowersCaps_andCannotPause() public {
        vm.prank(governor);
        store.setLaunchCap(0, 1_000e6);
        vm.prank(guardian);
        store.lowerLaunchCap(0, 500e6);
        assertEq(store.getLaunchCap(0), 500e6, "guardian tightens a cap");

        // Pausers and the unpauser cannot do the guardian's job.
        vm.prank(pauserA);
        vm.expectRevert(IDollarStore.OnlyGuardian.selector);
        store.lowerLaunchCap(0, 100e6);
        vm.prank(unpauser);
        vm.expectRevert(IDollarStore.OnlyGuardian.selector);
        store.lowerLaunchCap(0, 100e6);
    }

    /// @notice Each pause refuses a deposit for its own reason and leaves the exit open. Alice keeps
    ///         a balance and an allowance throughout, so a deposit can only fail because of the pause.
    function test_withdraw_staysOpenUnderEveryPause() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(store), 200e6);
        store.deposit(0, address(usdc), 100e6, alice, block.timestamp);
        vm.stopPrank();

        vm.prank(pauserA);
        store.pause();
        _depositReverts(abi.encodeWithSignature("EnforcedPause()"));
        _withdraws(10e6);
        vm.prank(unpauser);
        store.unpause();

        vm.prank(pauserA);
        store.pausePool(0);
        _depositReverts(abi.encodeWithSelector(IDollarStore.PoolPaused.selector, uint16(0)));
        _withdraws(10e6);
        vm.prank(unpauser);
        store.unpausePool(0);

        vm.prank(pauserA);
        store.pauseDeposits(address(usdc));
        _depositReverts(abi.encodeWithSelector(IDollarStore.DepositsPaused.selector, address(usdc)));
        _withdraws(10e6);

        // All three at once: the exit still pays.
        _pauseAll(pauserA);
        _withdraws(70e6);
        assertEq(usdc.balanceOf(alice), 200e6, "everything Alice put in is back with her");

        // With every pause lifted the same deposit goes through, so the pauses were what stopped it.
        _unpauseAll();
        vm.prank(alice);
        store.deposit(0, address(usdc), 1e6, alice, block.timestamp);
    }

    function _depositReverts(bytes memory reason) internal {
        vm.prank(alice);
        vm.expectRevert(reason);
        store.deposit(0, address(usdc), 1e6, alice, block.timestamp);
    }

    function _withdraws(uint256 units) internal {
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        store.withdraw(0, units, block.timestamp);
        assertEq(usdc.balanceOf(alice) - before, units, "exit paid in full while paused");
    }

    /// @notice A queued position can be cancelled, and its escrow returned, under the global pause,
    ///         a pool pause, an asset pause, and all three together.
    function test_cancelQueue_staysOpenUnderEveryPause() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(governor);
        store.addHubAsset(address(usdt), address(feed));

        // Four positions of 1,000 USDC each, above the minimum order size at every queue depth here. The hub holds no USDT, so each one queues in full.
        for (uint256 i; i < 4; ++i) {
            _queueUsdcFor(usdt, alice, 1_000e6);
        }
        uint256[] memory ids = store.getUserQueuePositions(alice);
        assertEq(ids.length, 4, "four positions queued");
        assertEq(usdc.balanceOf(alice), 0, "all of it is in escrow");

        vm.prank(pauserA);
        store.pause();
        _cancels(ids[0]);
        vm.prank(unpauser);
        store.unpause();

        vm.prank(pauserA);
        store.pausePool(0);
        _cancels(ids[1]);
        vm.prank(unpauser);
        store.unpausePool(0);

        vm.prank(pauserA);
        store.pauseDeposits(address(usdc));
        _cancels(ids[2]);

        _pauseAll(pauserA);
        _cancels(ids[3]);

        assertEq(usdc.balanceOf(alice), 4_000e6, "every position's escrow is back with Alice");
        assertEq(store.getQueueDepth(address(usdc), address(usdt)), 0, "nothing left queued");
    }

    function _cancels(uint256 positionId) internal {
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        store.cancelQueue(positionId);
        assertEq(usdc.balanceOf(alice) - before, 1_000e6, "escrow returned while paused");
    }

    /// @notice A pause delays queue settlement and changes nothing else: once it is lifted, the same
    ///         positions are paid the same amounts in the same order, and the pauser gains nothing.
    function test_pauseDelaysQueueSettlement_orderAndAmountsUnchanged() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(governor);
        store.addHubAsset(address(usdt), address(feed));
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        // Alice, then Carol, offer USDC for USDT. The hub holds no USDT, so both orders queue.
        _queueUsdcFor(usdt, alice, 500e6);
        _queueUsdcFor(usdt, carol, 600e6);
        uint256 aliceId = store.getUserQueuePositions(alice)[0];
        uint256 carolId = store.getUserQueuePositions(carol)[0];
        assertLt(aliceId, carolId, "Alice is ahead of Carol");

        usdt.mint(bob, 1_500e6);
        vm.startPrank(bob);
        usdt.approve(address(store), 1_500e6);
        store.deposit(0, address(usdt), 1_500e6, bob, block.timestamp);
        vm.stopPrank();

        vm.prank(pauserA);
        store.pauseDeposits(address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.DepositsPaused.selector, address(usdc)));
        store.processQueue(address(usdc), address(usdt), 2);
        assertEq(usdt.balanceOf(alice), 0, "nobody is paid while paused");
        assertEq(usdt.balanceOf(carol), 0, "nobody is paid while paused");
        assertEq(store.getQueueDepth(address(usdc), address(usdt)), 1_100e6, "both positions still queued in full");

        vm.prank(unpauser);
        store.unpauseDeposits(address(usdc));

        // One position at a time, to show the order: Alice first, then Carol.
        store.processQueue(address(usdc), address(usdt), 1);
        assertEq(usdt.balanceOf(alice), 500e6, "Alice is paid first, in full");
        assertEq(usdt.balanceOf(carol), 0, "Carol waits behind Alice");
        store.processQueue(address(usdc), address(usdt), 1);
        assertEq(usdt.balanceOf(carol), 600e6, "Carol is paid next, in full");

        assertEq(usdt.balanceOf(pauserA), 0, "the pauser gains nothing");
        assertEq(usdc.balanceOf(pauserA), 0, "the pauser gains nothing");
        assertEq(store.getQueueDepth(address(usdc), address(usdt)), 0, "queue is empty");
    }

    function _queueUsdcFor(MockERC20 want, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(store), amount);
        store.swapOrQueue(address(usdc), address(want), amount, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @notice Lifting a pause on a spoke that is winding down does not reopen it to deposits.
    function test_unpausingWindingDownSpoke_doesNotReopenDeposits() public {
        MockERC20 rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        vm.startPrank(governor);
        uint16 spoke = store.createSpoke(address(rlusd), address(feed), 0, 0);
        store.windDownSpoke(spoke);
        vm.stopPrank();

        vm.prank(pauserA);
        store.pausePool(spoke);
        vm.prank(unpauser);
        store.unpausePool(spoke);
        assertFalse(store.isPoolPaused(spoke), "pause lifted");

        rlusd.mint(alice, 1e18);
        vm.startPrank(alice);
        rlusd.approve(address(store), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.SpokeWindingDown.selector, spoke));
        store.deposit(spoke, address(rlusd), 1e18, alice, block.timestamp);
        vm.stopPrank();
    }

    function testFuzz_onlyListedAddressesPause(address caller) public {
        vm.assume(caller != pauserA && caller != pauserB);
        vm.prank(caller);
        vm.expectRevert(IDollarStore.OnlyPauser.selector);
        store.pause();
    }

    function testFuzz_onlyTheUnpauserUnpauses(address caller) public {
        vm.assume(caller != unpauser);
        vm.prank(pauserA);
        store.pause();
        vm.prank(caller);
        vm.expectRevert(IDollarStore.OnlyUnpauser.selector);
        store.unpause();
    }
}
