// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice getSwapQuote reports what the swap would fill now, including when earlier same-direction
///         positions are waiting: the swap settles up to 8 of them from reserves first and fills the
///         caller from what is left. Tests compare the quote with the real swap, or show the swap
///         reverting where the quote is 0 or where the quote's documented limits apply.
contract SwapQuoteTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice"); // supplies reserves
    address internal bob = makeAddr("bob"); // the caller being quoted
    address internal carol = makeAddr("carol"); // waits in line

    MockERC20 internal usdc;
    MockBlacklistERC20 internal usdt; // can refuse a recipient
    MockERC20 internal rlusd; // 18dp spoke asset
    MockAggregatorV3 internal feed;
    uint16 internal spoke;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockBlacklistERC20("Tether", "USDT", 6);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usdt), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0);
        vm.stopPrank();

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; i++) {
            usdc.mint(users[i], 100_000_000e6);
            usdt.mint(users[i], 100_000_000e6);
            rlusd.mint(users[i], 100_000_000e18);
        }
    }

    function _deposit(uint16 poolId, ERC20 token, uint256 amt) internal {
        vm.startPrank(alice);
        token.approve(address(store), amt);
        store.deposit(poolId, address(token), amt, block.timestamp);
        vm.stopPrank();
    }

    function _swap(address who, ERC20 offer, ERC20 want, uint256 amt) internal returns (uint256 filled) {
        vm.startPrank(who);
        offer.approve(address(store), amt);
        (filled,) = store.swap(address(offer), address(want), amt, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev What the swap fills now for `who`, read from swapExactInput and then rolled back: the full
    ///         amount on success, or the filled part from its InsufficientLiquidity revert. Outputs here
    ///         are 6-decimal tokens, so native and normalized units are equal.
    function _fillsNow(address who, ERC20 offer, ERC20 want, uint256 amt) internal returns (uint256 filled) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(who);
        offer.approve(address(store), amt);
        try store.swapExactInput(address(offer), address(want), amt, 0, block.timestamp) returns (uint256 out) {
            filled = out;
        } catch (bytes memory err) {
            assertEq(bytes4(err), IDollarStore.InsufficientLiquidity.selector, "only a liquidity shortfall");
            (filled,) = abi.decode(_args(err), (uint256, uint256));
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _args(bytes memory err) internal pure returns (bytes memory a) {
        a = new bytes(err.length - 4);
        for (uint256 i; i < a.length; i++) {
            a[i] = err[i + 4];
        }
    }

    /// @dev Carol queues `n` USDC -> USDT orders of `size` while the hub holds no USDT.
    function _queueAhead(uint256 n, uint256 size) internal {
        for (uint256 i; i < n; i++) {
            assertEq(_swap(carol, usdc, usdt, size), 0, "queued: no USDT in the hub");
        }
    }

    function _quoteThenSwap(uint256 amount) internal returns (uint256 quoted, uint256 filled) {
        quoted = store.getSwapQuote(address(usdc), address(usdt), amount);
        filled = _fillsNow(bob, usdc, usdt, amount);
    }

    // ============ waiting in the same direction ============

    function test_quote_enoughForThoseAheadAndCaller_quotesFullAmount() public {
        _queueAhead(1, 300e6);
        _deposit(0, usdt, 500e6);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(200e6);

        assertEq(quoted, 200e6, "quote");
        assertEq(filled, quoted, "swap fills what was quoted");
        assertEq(_swap(bob, usdc, usdt, 200e6), 200e6, "and does, for real");
        assertEq(store.getQueueDepth(address(usdc), address(usdt)), 0, "carol paid first");
    }

    function test_quote_thoseAheadTakeEverything_quotesZero() public {
        _queueAhead(1, 300e6);
        _deposit(0, usdt, 250e6);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(200e6);

        assertEq(quoted, 0, "quote");
        assertEq(filled, 0, "swap fills nothing");
    }

    function test_quote_thoseAheadLeaveSome_quotesTheRest() public {
        _queueAhead(1, 300e6);
        _deposit(0, usdt, 400e6);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(200e6);

        assertEq(quoted, 100e6, "quote");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    function test_quote_eightAhead_quotesTheRest() public {
        _queueAhead(8, 500e6);
        _deposit(0, usdt, 10_000e6);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(500e6);

        assertEq(quoted, 500e6, "eight settled, then the caller");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    function test_quote_nineAhead_quotesZero() public {
        _queueAhead(9, 500e6);
        _deposit(0, usdt, 10_000e6);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(500e6);

        assertEq(quoted, 0, "one call settles only eight, the ninth still blocks reserves");
        assertEq(filled, 0, "swap fills nothing");
    }

    function test_quote_spokeToHub_waitingAndFloor() public {
        _deposit(spoke, usdc, 1_000e6); // spoke claim 1,000, hub USDC 1,000
        vm.prank(governor);
        store.setMinDlrsReserve(spoke, 1_000e6);
        assertEq(_swap(carol, rlusd, usdc, 300e18), 0, "carol queues at the floor");
        vm.prank(governor);
        store.setMinDlrsReserve(spoke, 500e6); // 500 above the floor

        uint256 quoted = store.getSwapQuote(address(rlusd), address(usdc), 300e18);
        uint256 filled = _fillsNow(bob, rlusd, usdc, 300e18);

        assertEq(quoted, 200e6, "500 above the floor, carol's 300 first");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    // ============ opposite direction ============

    /// @dev Carol queues `amt` USDT -> USDC while the hub holds no USDC, so her USDT is matched first.
    function _queueOpposite(uint256 amt) internal {
        vm.startPrank(carol);
        usdt.approve(address(store), amt);
        (uint256 filled,) = store.swap(address(usdt), address(usdc), amt, 0, 0, block.timestamp);
        vm.stopPrank();
        assertEq(filled, 0, "queued: no USDC in the hub");
    }

    function test_quote_oppositeSmallerThanAmount() public {
        _queueOpposite(300e6);
        (uint256 quoted, uint256 filled) = _quoteThenSwap(500e6);
        assertEq(quoted, 300e6, "only carol's 300");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    function test_quote_oppositeEqualToAmount() public {
        _queueOpposite(500e6);
        (uint256 quoted, uint256 filled) = _quoteThenSwap(500e6);
        assertEq(quoted, 500e6, "carol covers it");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    function test_quote_oppositeLargerThanAmount() public {
        _queueOpposite(800e6);
        (uint256 quoted, uint256 filled) = _quoteThenSwap(500e6);
        assertEq(quoted, 500e6, "capped at the amount");
        assertEq(filled, quoted, "swap fills what was quoted");
    }

    function test_quote_opposite_18dpWant_nativeUnits() public {
        assertEq(_swap(carol, rlusd, usdc, 300e18), 0, "carol queues: the spoke has no hub claim");

        uint256 quoted = store.getSwapQuote(address(usdc), address(rlusd), 200e6);
        assertEq(quoted, 200e18, "native RLUSD units");
        assertEq(_fillsNow(bob, usdc, rlusd, 200e6), quoted, "swap delivers what was quoted");
    }

    // ============ zero where the swap would revert ============

    function _quoteIsZeroAndSwapReverts(bytes memory err) internal {
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 0, "quote");
        vm.startPrank(bob);
        usdc.approve(address(store), 100e6);
        if (err.length == 4) vm.expectPartialRevert(bytes4(err));
        else vm.expectRevert(err);
        store.swapExactInput(address(usdc), address(usdt), 100e6, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_quote_globalPause_zero() public {
        _deposit(0, usdt, 1_000e6);
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "positive before");
        vm.prank(guardian);
        store.pause();
        _quoteIsZeroAndSwapReverts(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
    }

    function test_quote_hubPoolPaused_zero() public {
        _deposit(0, usdt, 1_000e6);
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "positive before");
        vm.prank(guardian);
        store.pausePool(0);
        _quoteIsZeroAndSwapReverts(abi.encodeWithSelector(IDollarStore.PoolPaused.selector, uint16(0)));
    }

    function test_quote_offerDepositsPaused_zero() public {
        _deposit(0, usdt, 1_000e6);
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "positive before");
        vm.prank(guardian);
        store.pauseDeposits(address(usdc));
        _quoteIsZeroAndSwapReverts(abi.encodeWithSelector(IDollarStore.DepositsPaused.selector, address(usdc)));
    }

    function test_quote_offerOffPeg_zero() public {
        _deposit(0, usdt, 1_000e6);
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "positive before");
        feed.setAnswer(0.9e8);
        _quoteIsZeroAndSwapReverts(abi.encodePacked(IDollarStore.PriceOutOfBounds.selector));
    }

    function test_quote_offerPriceStale_zero() public {
        _deposit(0, usdt, 1_000e6);
        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "positive before");
        vm.warp(block.timestamp + 30 days);
        _quoteIsZeroAndSwapReverts(abi.encodePacked(IDollarStore.PriceStale.selector));
    }

    /// @dev Documented limit: the view does not know who will call, so it cannot see that this caller is
    ///      refused by the wanted token.
    function test_quote_callerCannotReceiveWant_quotePositiveSwapReverts() public {
        _deposit(0, usdt, 1_000e6);
        usdt.setBlocked(bob, true);

        assertEq(store.getSwapQuote(address(usdc), address(usdt), 100e6), 100e6, "quote assumes the payout works");
        vm.startPrank(bob);
        usdc.approve(address(store), 100e6);
        vm.expectRevert(bytes("blocked"));
        store.swapExactInput(address(usdc), address(usdt), 100e6, 0, block.timestamp);
        vm.stopPrank();
    }

    // ============ hub to hub with a line waiting ============

    function testFuzz_quote_hubToHubWithLineWaiting_matchesFill(
        uint8 ahead,
        uint256 size,
        uint256 reserve,
        uint256 amount
    ) public {
        ahead = uint8(bound(ahead, 0, 12));
        size = bound(size, 500e6, 5_000e6);
        reserve = bound(reserve, 0, 80_000e6);
        amount = bound(amount, 1e6, 20_000e6);
        _queueAhead(ahead, size);
        if (reserve > 0) _deposit(0, usdt, reserve);

        (uint256 quoted, uint256 filled) = _quoteThenSwap(amount);

        assertEq(filled, quoted, "swap fills exactly what was quoted");
    }
}
