// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice Swap entrypoints take and return native token amounts: minAmountOut, the amount delivered,
///         MinAmountNotMet and InsufficientLiquidity in the wanted asset; the amount pulled and the
///         amount queued in the offered asset; the Swap event in each asset's own units. Also the
///         position id from swapOrQueue and the recipient of the all-or-nothing swaps. Hub assets of 6,
///         8, 12 and 18 decimals.
contract SwapNativeUnitsTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; // 18 decimals
    MockERC20 internal t8; // 8 decimals
    MockERC20 internal t12; // 12 decimals

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize,
            (
                makeAddr("upgrader"),
                governor,
                makeAddr("guardian"),
                makeAddr("unpauser"),
                Pausers.one(makeAddr("pauser"))
            )
        );
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        t8 = new MockERC20("Eight", "T8", 8);
        t12 = new MockERC20("Twelve", "T12", 12);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);

        MockERC20[4] memory tokens = [usdc, dai, t8, t12];
        vm.startPrank(governor);
        for (uint256 i; i < tokens.length; ++i) {
            store.addHubAsset(address(tokens[i]), address(feed));
        }
        vm.stopPrank();
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].mint(alice, 1_000_000 * 10 ** tokens[i].decimals());
            tokens[i].mint(bob, 1_000_000 * 10 ** tokens[i].decimals());
        }
    }

    function _deposit(MockERC20 token, uint256 amount) internal {
        vm.startPrank(bob);
        token.approve(address(store), amount);
        store.deposit(0, address(token), amount, bob, block.timestamp);
        vm.stopPrank();
    }

    function _approve(address who, MockERC20 token, uint256 amount) internal {
        vm.prank(who);
        token.approve(address(store), amount);
    }

    function _minNotMet(address want, uint256 amountOut, uint256 minAmountOut) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IDollarStore.MinAmountNotMet.selector, want, amountOut, minAmountOut);
    }

    // ============ minAmountOut ============

    /// @notice 6dp offer, 18dp want: a minimum one wei above the native output reverts; the exact
    ///         native output passes.
    function test_swapExactInput_minAmountOut_6to18() public {
        _deposit(dai, 1_000e18);
        _approve(alice, usdc, 1_000e6);

        vm.startPrank(alice);
        vm.expectRevert(_minNotMet(address(dai), 1_000e18, 1_000e18 + 1));
        store.swapExactInput(address(usdc), address(dai), 1_000e6, 1_000e18 + 1, alice, block.timestamp);
        (uint256 amountIn, uint256 out) =
            store.swapExactInput(address(usdc), address(dai), 1_000e6, 1_000e18, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, 1_000e6, "native USDC pulled");
        assertEq(out, 1_000e18, "native DAI out");
    }

    /// @notice 18dp offer, 6dp want: the minimum is in 6dp native USDC.
    function test_swapExactInput_minAmountOut_18to6() public {
        _deposit(usdc, 1_000e6);
        _approve(alice, dai, 1_000e18);

        vm.startPrank(alice);
        vm.expectRevert(_minNotMet(address(usdc), 1_000e6, 1_000e6 + 1));
        store.swapExactInput(address(dai), address(usdc), 1_000e18, 1_000e6 + 1, alice, block.timestamp);
        (uint256 amountIn, uint256 out) =
            store.swapExactInput(address(dai), address(usdc), 1_000e18, 1_000e6, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, 1_000e18, "native DAI pulled");
        assertEq(out, 1_000e6, "native USDC out");
    }

    /// @notice A minimum that is not a multiple of the want scaling factor is not rounded down: an
    ///         output of 400e18 does not meet 400e18 + 1 even though both are 400e6 units.
    function test_swapOrQueue_minAmountOut_notRoundedDown() public {
        _deposit(dai, 400e18);
        _approve(alice, usdc, 1_000e6);

        vm.startPrank(alice);
        vm.expectRevert(_minNotMet(address(dai), 400e18, 400e18 + 1));
        store.swapOrQueue(address(usdc), address(dai), 1_000e6, 400e18 + 1, block.timestamp);
        (uint256 amountIn, uint256 out, uint256 queued, uint256 id) =
            store.swapOrQueue(address(usdc), address(dai), 1_000e6, 400e18, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, 1_000e6, "native USDC pulled, queued part included");
        assertEq(out, 400e18, "native DAI delivered now");
        assertEq(queued, 600e6, "native USDC escrowed");
        assertEq(id, store.getUserQueuePositions(alice)[0], "position id returned");
    }

    /// @notice One wanted unit out (1e12 wei of DAI) meets minimums of 1 and 1e12, not 1e12 + 1.
    function test_minAmountOut_smallestUnit() public {
        _deposit(dai, 3e12);
        _approve(alice, usdc, 3);

        vm.startPrank(alice);
        vm.expectRevert(_minNotMet(address(dai), 1e12, 1e12 + 1));
        store.swapExactInput(address(usdc), address(dai), 1, 1e12 + 1, alice, block.timestamp);
        (, uint256 out) = store.swapExactInput(address(usdc), address(dai), 1, 1e12, alice, block.timestamp);
        assertEq(out, 1e12, "minimum = output");
        (, out) = store.swapExactInput(address(usdc), address(dai), 1, 1, alice, block.timestamp);
        assertEq(out, 1e12, "minimum of one wei");
        vm.stopPrank();
    }

    /// @notice Nothing fills now: any positive minimum reverts with a zero native fill.
    function test_swapOrQueue_zeroFill_positiveMinimumReverts() public {
        _approve(alice, usdc, 600e6);

        vm.prank(alice);
        vm.expectRevert(_minNotMet(address(dai), 0, 1));
        store.swapOrQueue(address(usdc), address(dai), 600e6, 1, block.timestamp);
    }

    // ============ returns and errors ============

    /// @notice 18dp offer partly filled: the queued remainder is returned in native offer units and
    ///         the stored position stays in 6dp units.
    function test_swapOrQueue_returnsQueuedInNativeOffer() public {
        _deposit(usdc, 400e6);
        _approve(alice, dai, 1_000e18);

        vm.prank(alice);
        (uint256 amountIn, uint256 out, uint256 queued, uint256 id) =
            store.swapOrQueue(address(dai), address(usdc), 1_000e18, 400e6, block.timestamp);

        assertEq(amountIn, 1_000e18, "native DAI pulled");
        assertEq(out, 400e6, "native USDC delivered now");
        assertEq(queued, 600e18, "native DAI escrowed");
        (address owner,,, uint256 positionUnits,,) = store.getQueuePosition(id);
        assertEq(owner, alice, "caller owns the position");
        assertEq(positionUnits, 600e6, "position stays in 6dp units");
    }

    /// @notice A full fill queues nothing and returns position id 0.
    function test_swapOrQueue_fullFill_positionIdZero() public {
        _deposit(dai, 1_000e18);
        _approve(alice, usdc, 1_000e6);

        vm.prank(alice);
        (,, uint256 queued, uint256 id) = store.swapOrQueue(address(usdc), address(dai), 1_000e6, 0, block.timestamp);

        assertEq(queued, 0, "nothing queued");
        assertEq(id, 0, "no position");
        assertEq(store.getUserQueuePositions(alice).length, 0, "none stored");
    }

    /// @notice swapExactInput short on an 18dp want reports the want asset and both amounts in native
    ///         DAI, and moves nothing.
    function test_swapExactInput_shortfall_isNativeWant() public {
        _deposit(dai, 400e18);
        _approve(alice, usdc, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDollarStore.InsufficientLiquidity.selector, address(dai), 400e18, 1_000e18)
        );
        store.swapExactInput(address(usdc), address(dai), 1_000e6, 0, alice, block.timestamp);

        assertEq(usdc.balanceOf(alice), 1_000_000e6, "nothing pulled");
        assertEq(store.getReserve(0, address(dai)), 400e6, "reserve untouched");
    }

    /// @notice 8dp offer with dust, 12dp want: the 12dp scale governs output and minimum, the 8dp
    ///         scale governs the pull and the queued return.
    function test_swapOrQueue_8to12() public {
        _deposit(t12, 400e12);
        uint256 amount = 1_000e8 + 99; // 99 wei of dust, one wei below the next 6dp unit
        _approve(alice, t8, amount);

        vm.startPrank(alice);
        vm.expectRevert(_minNotMet(address(t12), 400e12, 400e12 + 1));
        store.swapOrQueue(address(t8), address(t12), amount, 400e12 + 1, block.timestamp);
        (uint256 amountIn, uint256 out, uint256 queued,) =
            store.swapOrQueue(address(t8), address(t12), amount, 400e12, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, 1_000e8, "dust not pulled");
        assertEq(out, 400e12, "native T12 out");
        assertEq(queued, 600e8, "native T8 escrowed");
        assertEq(t8.balanceOf(alice), 1_000_000e8 - 1_000e8, "only whole units pulled");
        assertEq(t12.balanceOf(alice), 1_000_000e12 + 400e12, "T12 received");
    }

    /// @notice Input one wei short of a 6dp unit of DAI is zero; exactly one unit swaps.
    function test_swap_inputBelowOneUnit() public {
        _deposit(usdc, 1e6);
        _approve(alice, dai, 1e12);

        vm.startPrank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.swapExactInput(address(dai), address(usdc), 1e12 - 1, 0, alice, block.timestamp);
        (uint256 amountIn, uint256 out) =
            store.swapExactInput(address(dai), address(usdc), 1e12, 1, alice, block.timestamp);
        vm.stopPrank();
        assertEq(amountIn, 1e12, "one unit pulled");
        assertEq(out, 1, "one unit out");
    }

    // ============ Swap event ============

    /// @notice swapOrQueue 18dp -> 6dp, partly filled.
    function test_swapEvent_partial_18to6() public {
        _deposit(usdc, 400e6);
        _approve(alice, dai, 1_000e18);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(dai), address(usdc), alice, 1_000e18, 400e6, 600e18);
        vm.prank(alice);
        store.swapOrQueue(address(dai), address(usdc), 1_000e18, 0, block.timestamp);
    }

    /// @notice swapOrQueue 6dp -> 18dp, partly filled.
    function test_swapEvent_partial_6to18() public {
        _deposit(dai, 400e18);
        _approve(alice, usdc, 1_000e6);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(usdc), address(dai), alice, 1_000e6, 400e18, 600e6);
        vm.prank(alice);
        store.swapOrQueue(address(usdc), address(dai), 1_000e6, 0, block.timestamp);
    }

    /// @notice swapOrQueue with sub-unit input dust: the event reports what was pulled, and the dust
    ///         stays.
    function test_swapEvent_dustStaysWithCaller() public {
        _deposit(usdc, 1e6);
        uint256 amount = 1e18 + 1e12 - 1; // one wei below the next 6dp unit
        _approve(alice, dai, amount);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(dai), address(usdc), alice, 1e18, 1e6, 0);
        vm.prank(alice);
        store.swapOrQueue(address(dai), address(usdc), amount, 0, block.timestamp);

        assertEq(dai.balanceOf(alice), 1_000_000e18 - 1e18, "only whole units pulled");
    }

    /// @notice swapExactInput in both directions, 18dp input with dust.
    function test_swapEvent_exactInput() public {
        _deposit(usdc, 1_000e6);
        _deposit(dai, 1_000e18);
        _approve(alice, dai, 500e18 + 5);
        _approve(alice, usdc, 300e6);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(dai), address(usdc), alice, 500e18, 500e6, 0);
        vm.prank(alice);
        store.swapExactInput(address(dai), address(usdc), 500e18 + 5, 0, alice, block.timestamp);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(usdc), address(dai), alice, 300e6, 300e18, 0);
        vm.prank(alice);
        store.swapExactInput(address(usdc), address(dai), 300e6, 0, alice, block.timestamp);
    }

    // ============ recipient ============

    /// @notice The output goes to the recipient; the input comes from the caller, who receives
    ///         nothing. The event names both.
    function test_swapExactInput_recipientReceives() public {
        _deposit(dai, 1_000e18);
        _approve(alice, usdc, 1_000e6);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(usdc), address(dai), carol, 1_000e6, 1_000e18, 0);
        vm.prank(alice);
        store.swapExactInput(address(usdc), address(dai), 1_000e6, 1_000e18, carol, block.timestamp);

        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6, "caller paid");
        assertEq(dai.balanceOf(alice), 1_000_000e18, "caller received nothing");
        assertEq(dai.balanceOf(carol), 1_000e18, "recipient received");
    }

    /// @notice The zero address and DollarStore itself are rejected before any token call: alice has
    ///         not approved USDC, so a check after the pull would revert on the allowance instead.
    function test_swapExactInput_invalidRecipient() public {
        _deposit(dai, 1_000e18);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(0)));
        store.swapExactInput(address(usdc), address(dai), 1_000e6, 0, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(store)));
        store.swapExactInput(address(usdc), address(dai), 1_000e6, 0, address(store), block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1_000_000e6, "nothing pulled");
    }

    /// @dev Lists an 18-decimal hub token with a blocklist and funds bob with it.
    function _frozenToken() internal returns (MockBlacklistERC20 frz) {
        frz = new MockBlacklistERC20("Frz", "FRZ", 18);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.addHubAsset(address(frz), address(feed));
        frz.mint(bob, 1_000e18);
    }

    /// @notice A recipient the wanted token refuses reverts the whole swap, including the maker it had
    ///         already paid from the opposite queue: nothing pulled, the maker's position and payout
    ///         rolled back, nothing parked or queued.
    function test_swapExactInput_recipientRefused_revertsAll() public {
        MockBlacklistERC20 frz = _frozenToken();
        vm.startPrank(bob);
        frz.approve(address(store), 1_000e18);
        (,,, uint256 makerId) = store.swapOrQueue(address(frz), address(usdc), 1_000e18, 0, block.timestamp);
        vm.stopPrank();
        frz.setBlocked(carol, true);
        _approve(alice, usdc, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        store.swapExactInput(address(usdc), address(frz), 1_000e6, 0, carol, block.timestamp);

        assertEq(usdc.balanceOf(alice), 1_000_000e6, "nothing pulled");
        assertEq(usdc.balanceOf(bob), 1_000_000e6, "maker's payout rolled back");
        (,,, uint256 makerUnits,,) = store.getQueuePosition(makerId);
        assertEq(makerUnits, 1_000e6, "maker's position untouched");
        assertFalse(store.isQueuePositionParked(makerId), "maker not parked");
        assertEq(store.getUserQueuePositions(alice).length, 0, "nothing queued");
    }

    /// @notice A caller the wanted token refuses can still send the output to an allowed recipient.
    function test_swapExactInput_callerRefusedByWantToken_allowedRecipientReceives() public {
        MockBlacklistERC20 frz = _frozenToken();
        vm.startPrank(bob);
        frz.approve(address(store), 1_000e18);
        store.deposit(0, address(frz), 1_000e18, bob, block.timestamp);
        vm.stopPrank();
        frz.setBlocked(alice, true);
        _approve(alice, usdc, 1_000e6);

        vm.prank(alice);
        (uint256 amountIn, uint256 out) =
            store.swapExactInput(address(usdc), address(frz), 1_000e6, 1_000e18, carol, block.timestamp);

        assertEq(amountIn, 1_000e6, "alice paid");
        assertEq(out, 1_000e18, "output");
        assertEq(frz.balanceOf(carol), 1_000e18, "carol received");
    }

    // ============ gross returns ============

    /// @notice Alice queues 100 DAI for USDC, then swaps 100 USDC for DAI to herself and fills her own
    ///         order. The return reports this call's transfers, (100e6, 100e18), even though her USDC
    ///         balance does not move: her earlier position is paid the same 100 USDC.
    function test_swapExactInput_selfMatch_reportsGrossAmounts() public {
        _approve(alice, dai, 100e18);
        vm.prank(alice);
        store.swapOrQueue(address(dai), address(usdc), 100e18, 0, block.timestamp);
        _approve(alice, usdc, 100e6);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) =
            store.swapExactInput(address(usdc), address(dai), 100e6, 100e18, alice, block.timestamp);

        assertEq(amountIn, 100e6, "gross input");
        assertEq(amountOut, 100e18, "gross output");
        assertEq(usdc.balanceOf(alice), usdcBefore, "net USDC unchanged: paid in and paid back");
    }

    /// @notice Carol waits with an order to buy 100 DAI. Alice's swap first settles Carol's order from
    ///         reserves, then fills itself, sending its 100 DAI to Carol too. amountOut is Alice's 100,
    ///         not the 200 DAI Carol received in the call.
    function test_swapExactInput_recipientWithOlderOrder_excludesItsPayout() public {
        usdc.mint(carol, 100e6);
        _approve(carol, usdc, 100e6);
        vm.prank(carol);
        store.swapOrQueue(address(usdc), address(dai), 100e6, 0, block.timestamp); // no DAI: queued
        _deposit(dai, 200e18);
        _approve(alice, usdc, 100e6);

        vm.prank(alice);
        (, uint256 amountOut) = store.swapExactInput(address(usdc), address(dai), 100e6, 100e18, carol, block.timestamp);

        assertEq(amountOut, 100e18, "this swap's output only");
        assertEq(dai.balanceOf(carol), 200e18, "carol also got her own order's 100");
    }

    // ============ opposite queue across decimals ============

    /// @notice An 18dp maker partly filled by a 6dp taker, then by an exact-input taker, then
    ///         cancelled: native transfers, 6dp queue events.
    function test_oppositeQueue_partialFillAndCancel() public {
        _approve(alice, dai, 1_000e18);
        vm.prank(alice);
        (,,, uint256 id) = store.swapOrQueue(address(dai), address(usdc), 1_000e18, 0, block.timestamp);

        _approve(bob, usdc, 600e6);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.QueueFilled(id, alice, 400e6, 600e6);
        vm.prank(bob);
        (, uint256 out, uint256 queued,) = store.swapOrQueue(address(usdc), address(dai), 400e6, 0, block.timestamp);
        assertEq(out, 400e18, "taker gets native DAI");
        assertEq(queued, 0, "nothing queued");

        vm.prank(bob);
        (, out) = store.swapExactInput(address(usdc), address(dai), 200e6, 200e18, bob, block.timestamp);
        assertEq(out, 200e18, "exact-input taker gets native DAI");
        assertEq(usdc.balanceOf(alice), 1_000_000e6 + 600e6, "maker paid in native USDC");

        uint256 before = dai.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.QueueCancelled(id, alice, 400e6);
        vm.prank(alice);
        store.cancelQueue(id);
        assertEq(dai.balanceOf(alice) - before, 400e18, "native DAI refunded");
    }

    /// @notice A taker larger than the 18dp maker consumes it and queues its own 6dp remainder.
    function test_oppositeQueue_takerRemainderQueues() public {
        _approve(alice, dai, 1_000e18);
        vm.prank(alice);
        store.swapOrQueue(address(dai), address(usdc), 1_000e18, 0, block.timestamp);

        _approve(bob, usdc, 1_500e6);
        vm.prank(bob);
        (, uint256 out, uint256 queued,) = store.swapOrQueue(address(usdc), address(dai), 1_500e6, 0, block.timestamp);

        assertEq(out, 1_000e18, "maker's whole escrow, native DAI");
        assertEq(queued, 500e6, "taker's remainder, native USDC");
        assertEq(store.getQueueDepth(address(dai), address(usdc)), 0, "maker filled");
        assertEq(store.getQueueDepth(address(usdc), address(dai)), 500e6, "taker queued, 6dp depth");
    }

    // ============ rounding boundaries across decimals ============

    /// @dev Lists a fresh hub token with `d` decimals and funds alice and bob.
    function _listed(uint8 d) internal returns (MockERC20 t) {
        t = new MockERC20("T", "T", d);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.addHubAsset(address(t), address(feed));
        t.mint(alice, type(uint128).max);
        t.mint(bob, type(uint128).max);
    }

    /// @notice For any offered and wanted decimals in 6..18 and an input at k*So - 1, k*So, k*So + 1
    ///         or k*So + So - 1: the quote, the exact-input returns and the caller's debit follow
    ///         U = floor(amount / So), pulled U*So, output U*Sw; dust below So stays with the caller.
    function testFuzz_exactInput_boundaries(uint8 dO, uint8 dW, uint256 k, uint8 pick) public {
        dO = uint8(bound(dO, 6, 18));
        dW = uint8(bound(dW, 6, 18));
        k = bound(k, 1, 1e9);
        MockERC20 o = _listed(dO);
        MockERC20 w = _listed(dW);
        uint256 so = 10 ** (dO - 6);
        uint256 sw = 10 ** (dW - 6);
        uint256 amount;
        if (pick % 4 == 0) amount = k * so - 1; // just below k units
        else if (pick % 4 == 1) amount = k * so; // exactly k units
        else if (pick % 4 == 2) amount = k * so + 1; // one wei above
        else amount = k * so + so - 1; // largest dust
        uint256 units = amount / so;

        vm.startPrank(bob);
        w.approve(address(store), 2e9 * sw);
        store.deposit(0, address(w), 2e9 * sw, bob, block.timestamp);
        vm.stopPrank();

        assertEq(store.getSwapQuote(address(o), address(w), amount), units * sw, "quote");
        uint256 oBefore = o.balanceOf(alice);
        uint256 wBefore = w.balanceOf(alice);
        vm.startPrank(alice);
        o.approve(address(store), amount);
        if (units == 0) {
            vm.expectRevert(IDollarStore.ZeroAmount.selector);
            store.swapExactInput(address(o), address(w), amount, 0, alice, block.timestamp);
            vm.stopPrank();
            return;
        }
        vm.expectRevert(_minNotMet(address(w), units * sw, units * sw + 1));
        store.swapExactInput(address(o), address(w), amount, units * sw + 1, alice, block.timestamp);
        (uint256 amountIn, uint256 out) =
            store.swapExactInput(address(o), address(w), amount, units * sw, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, units * so, "amountIn");
        assertEq(out, units * sw, "output");
        assertEq(w.balanceOf(alice) - wBefore, out, "credited");
        assertEq(oBefore - o.balanceOf(alice), amountIn, "debited exactly amountIn");
        assertLt(amount - amountIn, so, "dust below one unit");
    }

    /// @notice swapOrQueue filled from a reserve of R units (possibly none), any decimals: output F*Sw
    ///         with F = min(U, R), queued (U - F)*So, amountIn U*So = (out / Sw) * So + queued, a
    ///         position id exactly when something queued, the Swap event carries the same amounts,
    ///         balances move by exactly those amounts, and cancelling refunds (U - F)*So.
    function testFuzz_swapOrQueue_partialFill(uint8 dO, uint8 dW, uint256 u, uint256 r, uint256 dust) public {
        dO = uint8(bound(dO, 6, 18));
        dW = uint8(bound(dW, 6, 18));
        MockERC20 o = _listed(dO);
        MockERC20 w = _listed(dW);
        uint256 so = 10 ** (dO - 6);
        uint256 sw = 10 ** (dW - 6);
        u = bound(u, 1, 1e9);
        r = bound(r, 0, 1e9);
        uint256 amount = u * so + bound(dust, 0, so - 1);
        uint256 f = u < r ? u : r;

        if (r > 0) {
            vm.startPrank(bob);
            w.approve(address(store), r * sw);
            store.deposit(0, address(w), r * sw, bob, block.timestamp);
            vm.stopPrank();
        }
        uint256 oBefore = o.balanceOf(alice);
        uint256 wBefore = w.balanceOf(alice);

        vm.startPrank(alice);
        o.approve(address(store), amount);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(o), address(w), alice, u * so, f * sw, (u - f) * so);
        (uint256 amountIn, uint256 out, uint256 queued, uint256 id) =
            store.swapOrQueue(address(o), address(w), amount, f * sw, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, u * so, "amountIn");
        assertEq(out, f * sw, "output");
        assertEq(queued, (u - f) * so, "queued in offered units");
        assertEq(amountIn, (out / sw) * so + queued, "amountIn = filled + queued");
        assertEq(id != 0, queued > 0, "position id exactly when queued");
        assertEq(oBefore - o.balanceOf(alice), amountIn, "debited exactly amountIn");
        assertEq(w.balanceOf(alice) - wBefore, out, "credited");
        assertEq(store.getReserve(0, address(w)), r - f, "want reserve in 6dp units");
        assertEq(store.getQueueDepth(address(o), address(w)), u - f, "queue depth in 6dp units");
        if (id != 0) {
            vm.prank(alice);
            store.cancelQueue(id);
            assertEq(oBefore - o.balanceOf(alice), f * so, "refund is the queued native amount");
        }
    }

    /// @dev Creates a spoke for a fresh token with `d` decimals and funds alice and bob.
    function _spoke(uint8 d) internal returns (MockERC20 t, uint16 poolId) {
        t = new MockERC20("S", "S", d);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        poolId = store.createSpoke(address(t), address(feed), 0, 0);
        t.mint(alice, type(uint128).max);
        t.mint(bob, type(uint128).max);
    }

    /// @notice Spoke-to-spoke with the offered, wanted and hub decimals each in 6..18: the output is
    ///         U*Sw whatever the hub's scale, paid to the recipient; with the wanted spoke holding
    ///         R < U units, the call reverts InsufficientLiquidity(want, R*Sw, U*Sw).
    function testFuzz_spokeToSpoke_independentDecimals(uint8 dO, uint8 dW, uint8 dH, uint256 u, uint256 dust) public {
        dO = uint8(bound(dO, 6, 18));
        dW = uint8(bound(dW, 6, 18));
        dH = uint8(bound(dH, 6, 18));
        (MockERC20 o, uint16 poolO) = _spoke(dO);
        (MockERC20 w, uint16 poolW) = _spoke(dW);
        MockERC20 h = _listed(dH);
        uint256 so = 10 ** (dO - 6);
        uint256 sw = 10 ** (dW - 6);
        uint256 sh = 10 ** (dH - 6);
        u = bound(u, 2, 1e9);
        uint256 amount = u * so + bound(dust, 0, so - 1);
        address[] memory via = new address[](1);
        via[0] = address(h);

        vm.startPrank(bob);
        h.approve(address(store), u * sh);
        store.deposit(poolO, address(h), u * sh, bob, block.timestamp); // offered spoke's hub claim
        w.approve(address(store), (u - 1) * sw);
        store.deposit(poolW, address(w), (u - 1) * sw, bob, block.timestamp); // one unit short
        vm.stopPrank();

        vm.startPrank(alice);
        o.approve(address(store), amount);
        vm.expectRevert(
            abi.encodeWithSelector(IDollarStore.InsufficientLiquidity.selector, address(w), (u - 1) * sw, u * sw)
        );
        store.swapSpokeToSpoke(address(o), address(w), via, amount, carol, block.timestamp);
        vm.stopPrank();

        vm.startPrank(bob);
        w.approve(address(store), sw);
        store.deposit(poolW, address(w), sw, bob, block.timestamp); // now exactly enough
        vm.stopPrank();

        uint256 oBefore = o.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(alice, address(o), address(w), carol, u * so, u * sw, 0);
        vm.prank(alice);
        (uint256 amountIn, uint256 out) =
            store.swapSpokeToSpoke(address(o), address(w), via, amount, carol, block.timestamp);

        assertEq(amountIn, u * so, "amountIn");
        assertEq(out, u * sw, "output");
        assertEq(oBefore - o.balanceOf(alice), amountIn, "debited exactly amountIn");
        assertEq(w.balanceOf(carol), out, "recipient credited");
        assertEq(store.getReserve(0, address(h)), u, "hub reserve unchanged, 6dp");
    }

    /// @notice swapSpokeToSpoke rejects the zero address and DollarStore as recipient before any token
    ///         call: alice has not approved the offered token.
    function test_swapSpokeToSpoke_invalidRecipient() public {
        (MockERC20 o,) = _spoke(6);
        (MockERC20 w,) = _spoke(18);
        address[] memory via = new address[](1);
        via[0] = address(usdc);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(0)));
        store.swapSpokeToSpoke(address(o), address(w), via, 100e6, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(store)));
        store.swapSpokeToSpoke(address(o), address(w), via, 100e6, address(store), block.timestamp);
        vm.stopPrank();
    }
}
